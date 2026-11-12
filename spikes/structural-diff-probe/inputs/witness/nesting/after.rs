fn update(state: &mut State, event: Event) {
    if event.is_relevant() {
        state.apply(event);
        state.save();
    }
    log(redact(state.summary()));
}
