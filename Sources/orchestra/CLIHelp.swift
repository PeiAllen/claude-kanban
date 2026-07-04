enum CLIHelp {
    static let text = """
    orchestra — drive the Orchestra daemon

    USAGE
      orchestra <command> [flags]

    COMMANDS
      list [--col plan|impl|review]              List cards
      spawn --prompt <p> --repo <r> --branch <b> [--model <m>] [--col plan|impl] [--seed <ctx>]
            spawn --prompt <p> --cwd <dir> [--read-only]   (freeform: run in an existing dir)
            spawn --prompt <p> --scratch                   (throwaway ~/.orchestra/scratch dir)
                                                 Spawn a new agent (prints its ref). --seed = fork context.
      move <ref> --col <plan|impl|review>        Move a card
      send <ref> <message...>                    Message the agent (inbox queue)
      send-keys <ref> <key|text...> [--text <literal>] [--window <w>]
                                                 Send live keystrokes (Esc, Up, C-c, Enter, text …)
      wait <ref...>                              Block until a watched card concludes (fan-out)
      handoff <ref> <context...>                 Clean-context handoff: resume the card seeded with context
      trust <path>                               Grant a human's write-trust for a dir (interactive only)
      trustState <path>                          Is a directory trusted? (read-only ledger query)
      status <ref>                               Show a card's state (JSON)
      archive <ref>                              Archive a card
      restart <ref>                              New blank session, same worktree
      resume <ref>                               Re-attempt claude --resume
      shell <ref>                                Attach the card's tmux session
      inspect <ref>                              Open a read-only claude in the card's worktree shell
      open-notes [ref]                           Open the card's worktree as an Obsidian vault, on its changed notes
      exec <ref> <cmd...>                        Run a one-shot command in the worktree
      sessions <ref> [--json]                    Debug handles (tmux targets + session id)
      batch-spawn --repo <r> --branch <b>        Spawn many (stdin: JSON array or one prompt/line)
      daemon [install|start|stop|status|uninstall]
      ping | version

    A <ref> is a card UUID, shortId, or orchestra://task/<ref> URI.
    Use `--` to end flag parsing when a message/command contains `--tokens`
      (e.g. orchestra send <ref> -- run with --verbose).
    Set ORCHESTRA_SOCK to target a non-default daemon socket.
    """
}
