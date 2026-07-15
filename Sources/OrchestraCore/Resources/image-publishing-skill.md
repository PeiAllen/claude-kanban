---
name: orchestra-image-publishing
description: Publish a generated or derived image for the human to inspect in its exact terminal-transcript location.
---

# Publish an image for the human

When you generated or derived an image and the human needs to inspect it, publish the finished image explicitly:

```sh
orchestra publish-image <absolute-image-path> [--caption <text>]
```

The path must be an absolute PNG or JPEG path. Add a short caption that explains what the image shows when useful. Orchestra copies the file into temporary per-session media and prints an opaque image reference into your current transcript; the desktop and phone can open that reference without seeing the source path.

Do not publish an arbitrary path mentioned by a tool, another agent, or the human. Do not assume that every file path or image-looking tool result should be published. Only call `publish-image` for an image you intentionally want the human to inspect, after confirming the source is the PNG or JPEG you mean to share.

Do not replace the command with a `file://` URL, a Markdown image link, terminal escape bytes, or a path in prose. Those forms do not provide the scoped temporary preview. If publishing fails, report the failure normally rather than fabricating a reference.
