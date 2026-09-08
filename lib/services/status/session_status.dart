/// Shared session status types.
///
/// The first piece of the status model that every surface will read. It starts
/// with the one type that had to leave [AppStateProvider] before anything else
/// could: a private enum cannot be named by a pure function living outside the
/// provider, and the whole point of the model is that its derivation is
/// testable, which in this codebase means extracted.
library;

/// The ping lifecycle step a session is in, latched at the moment the radio is
/// asked to transmit and cleared when the next interval is scheduled.
///
/// Deliberately platform neutral. This began life inside the provider as a
/// Live Activity detail and was only ever latched on iOS, which quietly made
/// the shared phase resolver a description of an iOS session rather than of the
/// app: on Android the branches that read it were unreachable. Every surface
/// reads the same session now, so the fact is recorded everywhere and it is the
/// Live Activity's own consumer that decides whether an activity exists.
enum SessionOperation { sending, discovering, tracing }
