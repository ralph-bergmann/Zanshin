import 'dart:convert';
import 'dart:io';

/// Serves the lab page on http://127.0.0.1:8768/.
///
/// Every `/api/layout` request runs `bin/lab_layout.dart` in a new process, so a change to the lab's
/// code shows on the next reload without a restart of this server.
///
/// usage: dart run spikes/graph-layout-lab/bin/lab_server.dart [port]
Future<void> main(List<String> args) async {
  final String lab = File.fromUri(Platform.script).parent.parent.path;
  final String packages = '${Directory(lab).parent.parent.path}/.dart_tool/package_config.json';
  final int port = args.isEmpty ? 8768 : int.parse(args[0]);
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('Graph layout lab: http://127.0.0.1:$port/');

  const pages = {'/': 'index.html', '/lab.js': 'lab.js', '/lab.css': 'lab.css'};
  const types = {'html': 'text/html', 'js': 'text/javascript', 'css': 'text/css'};
  final name = RegExp(r'^[A-Za-z0-9_-]+$');
  final ruleList = RegExp(r'^([a-z-]+(,[a-z-]+)*)?$');

  server.listen((HttpRequest request) async {
    final HttpResponse response = request.response;
    response.headers.set('cache-control', 'no-store');
    void send(int status, String type, String body) {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.parse('$type; charset=utf-8')
        ..write(body);
    }

    final String path = request.uri.path;
    final Map<String, String> q = request.uri.queryParameters;
    final String? page = pages[path];
    if (page != null) {
      send(200, types[page.split('.').last]!, File('$lab/web/$page').readAsStringSync());
    } else if (path == '/api/datasets') {
      final data = Directory('$lab/data');
      final List<String> sets = [
        if (data.existsSync())
          for (final FileSystemEntity f in data.listSync())
            if (f.path.endsWith('.json') && !f.path.endsWith('.meta.json'))
              f.uri.pathSegments.last.replaceAll('.json', ''),
      ]..sort();
      send(200, 'application/json', jsonEncode(sets));
    } else if (path == '/api/layout') {
      final String data = q['data'] ?? '';
      // The values become file names and process arguments: only known shapes pass.
      final bool valid =
          name.hasMatch(data) &&
          File('$lab/data/$data.json').existsSync() &&
          const {'lab', 'app'}.contains(q['engine']) &&
          const {'free', 'compact'}.contains(q['mode']) &&
          const {'0', '1'}.contains(q['stacks']) &&
          ruleList.hasMatch(q['rules'] ?? '');
      if (!valid) {
        send(400, 'text/plain', 'bad request');
      } else {
        final ProcessResult run = await Process.run(
          Platform.resolvedExecutable,
          [
            '--packages=$packages',
            'run',
            '$lab/bin/lab_layout.dart',
            '$lab/data',
            data,
            q['engine']!,
            q['mode']!,
            q['stacks']!,
            // Without `rules` the layout takes the rules' defaults.
            if (q.containsKey('rules')) q['rules']!,
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (run.exitCode == 0) {
          send(200, 'application/json', run.stdout as String);
        } else {
          send(500, 'text/plain', run.stderr as String);
        }
      }
    } else {
      send(404, 'text/plain', 'not found');
    }
    await response.close();
  });
}
