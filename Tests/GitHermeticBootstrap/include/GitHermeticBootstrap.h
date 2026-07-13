// Intentionally empty.
//
// GitHermeticBootstrap has no callable API: its only entry point is a load-time constructor (see
// bootstrap.c), which runs when the test bundle is loaded — no Swift code ever imports or calls it.
// SwiftPM requires a public headers directory for a C target, so this header exists to satisfy that
// and to say, to whoever opens it looking for the API, that there isn't one.

#ifndef ORCHESTRA_GIT_HERMETIC_BOOTSTRAP_H
#define ORCHESTRA_GIT_HERMETIC_BOOTSTRAP_H
#endif
