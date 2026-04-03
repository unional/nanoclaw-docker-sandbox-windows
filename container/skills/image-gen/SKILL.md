---
name: google-image-gen
---

# Image Generation

Generate images using Pollinations.ai (free, no API key required) and send them to the chat.

## Workflow

1. Generate the image using the `generate-image` CLI tool:
   ```bash
   generate-image "<your prompt here>" /workspace/group/generated-image.png
   ```
   The tool exits 0 on success and prints the output path. On failure it prints an error and exits non-zero.

2. Send the image using the `send_file` MCP tool:
   ```
   send_file(filePath: "generated-image.png", caption: "Here's your image!")
   ```
   `filePath` is relative to the group folder.

## Example

User: "Generate an image of a sunset over mountains"

```bash
generate-image "a golden sunset over mountain peaks, dramatic sky, photorealistic" /workspace/group/generated-image.png
```

Then call `send_file` with `filePath: "generated-image.png"` and a short caption describing what was generated.

## Notes

- Uses Pollinations.ai (free tier, no API key required).
- Optionally set `POLLINATIONS_API_KEY` in `.env` for higher rate limits (sk_ prefix key).
- Model: `flux` at 1024×1024. Override via the `IMAGEN_MODEL` env var if needed.
- Output format: JPEG (saved as .png, still works fine for sending).
- If generation fails, report the error to the user clearly.
