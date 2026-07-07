import Foundation

/// The single seam mapping a card's `Task.parentBranch` to the concrete git ref its diffs baseline
/// against (goal 1 — parent-relative diffs). Today the parent-ref string IS a local branch name, so
/// this is identity minus empty-string normalization. This is the ONE place BT6 extends to map the
/// remote form (`origin/<name>`) to its fetched private ref (`refs/orch/parents/<name>`).
///
/// Returns `nil` when the card has no parent — every consumer then falls back to the default-branch
/// baseline, keeping nil-parent behavior byte-identical to before the branch-tree feature.
extension OrchestraService {
    func resolvedParentRef(_ task: Task) -> String? {
        guard let pb = task.parentBranch, !pb.isEmpty else { return nil }
        return pb
    }
}
