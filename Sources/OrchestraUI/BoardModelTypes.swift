// Pure value types in BoardModel's public API. `CopyTarget` / `GoTarget` already live in OrchestraKit
// (moved by F1); `InspectorMode` moves here from App/Views/InspectorView.swift so the shared
// BoardModel can key its per-card inspector state on it.

/// The inspector's Agent vs Diff pane, tracked per card by `BoardModel`.
public enum InspectorMode { case agent, diff }
