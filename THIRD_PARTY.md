# Third-party software and models

Hush's own code is MIT. It does not bundle these; the installer downloads them from their official
sources and checks each file's SHA-256 (`scripts/engines.lock`).

| Component | Use | Licence | Source |
|---|---|---|---|
| whisper.cpp 1.9.5 (`whisper-server`) | speech-to-text engine | MIT | https://github.com/ggml-org/whisper.cpp (Homebrew `whisper-cpp`; the DMG build bundles it, built from source) |
| Sparkle 2.10.1 | in-app updates (DMG build only) | MIT | https://github.com/sparkle-project/Sparkle |
| Whisper large-v3-turbo (ggml q5_0 conversion) | speech-to-text model | MIT | https://huggingface.co/openai/whisper-large-v3-turbo · https://huggingface.co/ggerganov/whisper.cpp |
| sherpa-onnx v2.0.1 prebuilt (osx-arm64, shared, no-tts) | speaker diarization engine | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |
| pyannote segmentation-3.0 (ONNX export) | speech/speaker segmentation | MIT (© 2022 CNRS) | https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models |
| 3D-Speaker CAM++ zh_en common advanced | speaker embeddings | Apache-2.0 | https://github.com/modelscope/3D-Speaker · https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models |

Licences were read from each project's GitHub licence metadata and LICENSE files on 2026-11-16.
