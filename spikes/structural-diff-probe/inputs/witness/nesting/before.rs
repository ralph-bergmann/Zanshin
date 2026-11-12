fn update(state: &mut State, event: Event) {
    state.apply(event);
    state.save();
    log(state.summary());
}
