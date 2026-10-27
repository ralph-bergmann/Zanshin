// SPDX-License-Identifier: MIT

import 'dart:typed_data';

// Hand-written monomorphic sorts for the layout engine (Story 4.11). The SDK sorts typed lists
// through a generic quicksort with one closure call per comparison, which AOT cannot inline; these
// compare typed-array values inline (spike README, "Review 2026-09-26" §2). Every key the engine
// sorts by is total, so the result is unique and equals any correct sort's.

/// Runs up to this length are insertion-sorted before the merges.
const _run = 16;

/// Sorts the index array [items] stably, ascending by `key[item]` and then — when [second] is
/// given — by `second[item]`; ties keep the order [items] had. Start [items] ascending for an
/// index tie-break that is ascending, descending for one that is descending.
void sortIndicesStable(Int32List items, Int64List key, {Int32List? second}) {
  final int n = items.length;
  if (n < 2) {
    return;
  }
  for (var lo = 0; lo < n; lo += _run) {
    final int hi = lo + _run < n ? lo + _run : n;
    for (int i = lo + 1; i < hi; i++) {
      final int x = items[i];
      int j = i - 1;
      while (j >= lo && _after(items[j], x, key, second)) {
        items[j + 1] = items[j];
        j--;
      }
      items[j + 1] = x;
    }
  }
  if (n <= _run) {
    return;
  }
  // Bottom-up merges, alternating between [items] and one scratch array.
  var src = items;
  var dst = Int32List(n);
  for (int width = _run; width < n; width *= 2) {
    for (var lo = 0; lo < n; lo += 2 * width) {
      final int mid = lo + width < n ? lo + width : n;
      final int hi = lo + 2 * width < n ? lo + 2 * width : n;
      var a = lo;
      var b = mid;
      var k = lo;
      while (a < mid && b < hi) {
        // Take the left element unless the right one sorts strictly before it: stable.
        if (_after(src[a], src[b], key, second)) {
          dst[k++] = src[b++];
        } else {
          dst[k++] = src[a++];
        }
      }
      while (a < mid) {
        dst[k++] = src[a++];
      }
      while (b < hi) {
        dst[k++] = src[b++];
      }
    }
    final swap = src;
    src = dst;
    dst = swap;
  }
  if (!identical(src, items)) {
    items.setAll(0, src);
  }
}

/// Whether [a] sorts strictly after [b] by (`key`, `second`).
bool _after(int a, int b, Int64List key, Int32List? second) {
  final int ka = key[a];
  final int kb = key[b];
  if (ka != kb) {
    return ka > kb;
  }
  return second != null && second[a] > second[b];
}

/// Sorts the index array [items] stably, ascending by `key[item]` and then — when [second] is
/// given — by `second[item]` (Story 4.15's router: pixel keys). Same rules as [sortIndicesStable];
/// the keys must not be NaN.
void sortIndicesStableByDouble(Int32List items, Float64List key, {Float64List? second}) {
  final int n = items.length;
  if (n < 2) {
    return;
  }
  for (var lo = 0; lo < n; lo += _run) {
    final int hi = lo + _run < n ? lo + _run : n;
    for (int i = lo + 1; i < hi; i++) {
      final int x = items[i];
      int j = i - 1;
      while (j >= lo && _afterDouble(items[j], x, key, second)) {
        items[j + 1] = items[j];
        j--;
      }
      items[j + 1] = x;
    }
  }
  if (n <= _run) {
    return;
  }
  var src = items;
  var dst = Int32List(n);
  for (int width = _run; width < n; width *= 2) {
    for (var lo = 0; lo < n; lo += 2 * width) {
      final int mid = lo + width < n ? lo + width : n;
      final int hi = lo + 2 * width < n ? lo + 2 * width : n;
      var a = lo;
      var b = mid;
      var k = lo;
      while (a < mid && b < hi) {
        if (_afterDouble(src[a], src[b], key, second)) {
          dst[k++] = src[b++];
        } else {
          dst[k++] = src[a++];
        }
      }
      while (a < mid) {
        dst[k++] = src[a++];
      }
      while (b < hi) {
        dst[k++] = src[b++];
      }
    }
    final swap = src;
    src = dst;
    dst = swap;
  }
  if (!identical(src, items)) {
    items.setAll(0, src);
  }
}

/// Whether [a] sorts strictly after [b] by (`key`, `second`).
bool _afterDouble(int a, int b, Float64List key, Float64List? second) {
  final double ka = key[a];
  final double kb = key[b];
  if (ka != kb) {
    return ka > kb;
  }
  return second != null && second[a] > second[b];
}

/// Sorts `list[from ..< to]` ascending in place.
void sortInt64Range(Int64List list, int from, int to) {
  final int n = to - from;
  if (n < 2) {
    return;
  }
  for (int i = from + 1; i < to; i++) {
    final int x = list[i];
    if (list[i - 1] <= x) {
      continue;
    }
    if (n > _run) {
      _mergeSortInt64(list, from, to);
      return;
    }
    int j = i - 1;
    while (j >= from && list[j] > x) {
      list[j + 1] = list[j];
      j--;
    }
    list[j + 1] = x;
  }
}

/// Bottom-up merge sort of `list[from ..< to]` (more than [_run] values).
void _mergeSortInt64(Int64List list, int from, int to) {
  final int n = to - from;
  var src = Int64List.fromList(Int64List.sublistView(list, from, to));
  for (var lo = 0; lo < n; lo += _run) {
    final int hi = lo + _run < n ? lo + _run : n;
    for (int i = lo + 1; i < hi; i++) {
      final int x = src[i];
      int j = i - 1;
      while (j >= lo && src[j] > x) {
        src[j + 1] = src[j];
        j--;
      }
      src[j + 1] = x;
    }
  }
  var dst = Int64List(n);
  for (int width = _run; width < n; width *= 2) {
    for (var lo = 0; lo < n; lo += 2 * width) {
      final int mid = lo + width < n ? lo + width : n;
      final int hi = lo + 2 * width < n ? lo + 2 * width : n;
      var a = lo;
      var b = mid;
      var k = lo;
      while (a < mid && b < hi) {
        if (src[b] < src[a]) {
          dst[k++] = src[b++];
        } else {
          dst[k++] = src[a++];
        }
      }
      while (a < mid) {
        dst[k++] = src[a++];
      }
      while (b < hi) {
        dst[k++] = src[b++];
      }
    }
    final swap = src;
    src = dst;
    dst = swap;
  }
  list.setAll(from, src);
}
