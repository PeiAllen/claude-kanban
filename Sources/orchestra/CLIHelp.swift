enum CLIHelp {
    static let text = """
    orchestra — drive the Orchestra daemon

    USAGE
      orchestra <command> [flags]

    COMMANDS
      list [--col plan|impl|review]              List cards
      spawn --prompt <p> --repo <r> --branch <b> [--model <m>] [--col plan|impl]
                                                 Spawn a new agent (prints its ref)
      move <ref> --col <plan|impl|review>        Move a card
      send <ref> <message...>                    Message the agent
      status <ref>                               Show a card's state (JSON)
      archive <ref>                              Archive a card
      restart <ref>                              New blank session, same worktree
      resume <ref>                               Re-attempt claude --resume
      shell <ref>                                Attach the card's tmux session
      exec <ref> <cmd...>                        Run a one-shot command in the worktree
      sessions <ref> [--json]                    Debug handles (tmux targets + session id)
      batch-spawn --repo <r> --branch <b>        Spawn many (stdin: JSON array or one prompt/line)
      daemon [install|start|stop|status|uninstall]
      ping | version

    A <ref> is a card UUID, shortId, or orchestra://task/<ref> URI.
    Set ORCHESTRA_SOCK to target a non-default daemon socket.
    """
}
