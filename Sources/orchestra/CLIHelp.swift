enum CLIHelp {
    static let text = """
    orchestra — drive the Orchestra daemon

    USAGE
      orchestra <command> [flags]

    COMMANDS
      list [--col plan|impl|review]              List cards
      spawn --prompt <p> --repo <r> --branch <b> [--title <t>] [--note <n>] [--model <m>] [--col plan|impl] [--seed <ctx>] [--base <b>] [--id <uuid>]
            spawn --prompt <p> --cwd <dir> [--read-only]   (freeform: run in an existing dir)
            spawn --prompt <p> --scratch                   (throwaway ~/.orchestra/scratch dir)
                                                 Spawn a new agent (prints its ref). --seed = fork context.
                                                 --title = name the card (a seed is never used as a name;
                                                 unnamed cards fall back to branch / 👁 target / dir).
                                                 --base = create the branch on top of an existing local branch.
                                                 --id = reuse a client-minted UUID to make a retry idempotent.
      move <ref> --col <plan|impl|review>        Move a card
      set-title <ref> <title...>                 Rename a card (the agent session's name follows at its
                                                 next launch — it can't be renamed mid-session)
      set-note <ref> [text...]                   Set the card's durable note (what this card IS — e.g. its
                                                 wave/layer). Telemetry never overwrites it; empty clears it
      needs-input <ref> <question...>            Declare you're blocked on a decision only the card's owner
                                                 can make (set/replace; the daemon clears it when your next
                                                 turn starts — re-declare if still blocked)
      set-planned <ref> [n]                      Declare how many children this card's plan fans out (the `m`
                                                 of the n/m wave bar); 0 or absent clears it. Worktree cards only
      set-parent <ref> [parent] [--mode adopt|move] [--watch]
                                                 Set/clear a card branch's parent link (omit parent to clear).
                                                 --mode move transplants commits; --watch polls a remote parent (pr#/origin).
      tree [ref] [--repo <r>]                     Lineage snapshot (parent/children/base per card, JSON)
      synced <ref>                                Record you merged/restacked the parent down (clears the stale signal)
      merge-request <ref>                         Declare your work ready (the one ship verb): an owning
                                                  parent card is nudged to merge you; an unowned target
                                                  (main / bare / remote / none) is recorded for a human
      shipped <ref> [--force]                     Post-merge bookkeeping (notify child, retarget grandchildren); --force skips the merged-check
      borrow <ref>                                Cut a throwaway worktree to squash-merge into a bare parent (prints its path)
      release <ref>                               Tear down this card's borrow worktree
      send <ref> <message...>                    Message the agent (inbox queue)
      send-keys <ref> <key|text...> [--text <literal>] [--window <w>]
                                                 Send live keystrokes (Esc, Up, C-c, Enter, text …)
      wait <ref...>                              Block until a watched card concludes (fan-out)
      handoff <ref> <context...> [--model <id>]  Clean-context handoff: resume the card seeded with context
                                                 (--model also RE-SEATS it onto that model — escalate in place)
      trust <path>                               Grant a human's write-trust for a dir (interactive only)
      trustState <path>                          Is a directory trusted? (read-only ledger query)
      status <ref>                               Show a card's state (JSON)
      archive <ref>                              Archive a card
      restart <ref> [--model <id>]               New blank session, same worktree (--model re-seats it)
      resume <ref> [--model <id>]                Re-attempt resuming the card's session (--model re-seats it)
      shell <ref>                                Attach the card's tmux session
      inspect <ref>                              Open a read-only claude in the card's worktree shell
      open-notes [ref]                           Open the card's worktree as an Obsidian vault, on its changed notes
      exec <ref> <cmd...>                        Run a one-shot command in the worktree
      sessions <ref> [--json]                    Debug handles (tmux targets + session id)
      publish-image <absolute-path> [--caption <slug>]
                                                 Publish a temporary PNG/JPEG reference in this card's transcript
                                                 (caption: letters/digits/dashes, alphanumeric ends, 80 max —
                                                  it becomes the filename the human saves)
      shared <sync|status|resolve|adopt> [path...] [--ref <r>] [--json]
                                                 Shared agent files across worktrees. sync sends your edits and
                                                 receives others'; status shows policy, un-ignored leaves, a standing
                                                 conflict and the read-only git command for the store; resolve commits
                                                 a fixed conflict; adopt [path...] untracks paths from the project
                                                 and shares them (default: CLAUDE.md AGENTS.md .claude/commands/ship.md).
                                                 The card defaults to $ORCHESTRA_TASK_ID, else the card owning the cwd
      shared-policy <repo> [item [tracked|shared|ephemeral]]
                                                 Read or set a repo's per-item propagation policy (JSON)
      batch-spawn --repo <r> --branch <b>        Spawn many (stdin: JSON array or one prompt/line)
      daemon [install|start|stop|status|uninstall]
      ping | version

    A <ref> is a card UUID, shortId, or orchestra://task/<ref> URI.
    Use `--` to end flag parsing when a message/command contains `--tokens`
      (e.g. orchestra send <ref> -- run with --verbose).
    Set ORCHESTRA_SOCK to target a non-default daemon socket.
    """
}
