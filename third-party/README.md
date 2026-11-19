# Third-party acknowledgements

## Speech recognition

- **SuperDictate 0.2.21 / Parakey**, MIT. [Source](https://github.com/shlgd/SuperDictate/tree/v0.2.21). Its working local dictation implementation informed our choice of FluidAudio revision, Parakeet v3 model cache, language constraint and serial inference. The app and its interface are not bundled. Original attribution is preserved in `SuperDictate-NOTICE.md` and `SuperDictate-LICENSE.txt`.
- **FluidAudio**, Apache-2.0. [Source](https://github.com/FluidInference/FluidAudio/tree/313feb4bd692780a9a5b5fa9048fdb119486dde8). Linked into DialogSpeech; license in `FluidAudio-LICENSE.txt`.
- **NVIDIA Parakeet TDT 0.6B v3**, CC-BY-4.0. [Original model and attribution](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3); [CoreML conversion by FluidInference](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml). Downloaded separately to the user's model cache; weights are not included in the app bundle.
- **GigaAM v3**, MIT, GigaChat Team. [Source](https://github.com/salute-developers/GigaAM/tree/7447938d791c4f3e643386ee22c33777004293a5). Python dependency, weights downloaded separately; license in `GigaAM-LICENSE.txt`.
- **Silero VAD**, MIT, Silero Team. [Source](https://github.com/snakers4/silero-vad/tree/066409f3d9db45a30d21dfcbf9147826ffdd7052). ONNX model downloaded separately with a pinned SHA-256; license in `Silero-VAD-LICENSE.txt`.
- **MLX Whisper**, MIT, Apple Inc. [Source](https://github.com/ml-explore/mlx-examples/tree/main/whisper). Python dependency; license in `MLX-examples-LICENSE.txt`. [OpenAI Whisper models](https://github.com/openai/whisper), MIT, are converted by [MLX Community](https://huggingface.co/mlx-community); weights downloaded separately, original license in `Whisper-LICENSE.txt`.

## Native Markdown

- **MarkdownUI**, MIT, Guillermo Gonzalez. `MarkdownUI-LICENSE.txt`.
- **NetworkImage**, MIT, Guillermo Gonzalez. `NetworkImage-LICENSE.txt`.
- **swift-cmark / cmark-gfm**, BSD and MIT components. `swift-cmark-COPYING.txt`.

Dependency distributions retain their own license metadata. This folder is copied into the application's Resources directory.
