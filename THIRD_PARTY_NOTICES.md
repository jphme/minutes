# Third-party software and models

Minutes is MIT-licensed (see LICENSE). It builds on the following work.

## Code

- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference: speech recognition, voice
  activity detection and speaker diarization on the Apple Neural Engine. Apache License 2.0.

## Models (downloaded from Hugging Face on first launch, not included in this repository or the app)

| Model | Used for | License |
|---|---|---|
| [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml), Core ML conversion of [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra), a post-training of [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | speech recognition (default) | CC-BY-4.0 |
| [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | speech recognition (optional) | CC-BY-4.0 |
| [FluidInference/nemotron-labs-unified-asr-0.6b-coreml](https://huggingface.co/FluidInference/nemotron-labs-unified-asr-0.6b-coreml), NVIDIA Nemotron Unified ASR 0.6B | speech recognition (optional) | OpenMDW-1.1 |
| [FluidInference/parakeet-ctc-110m-coreml](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml) | custom vocabulary rescoring | CC-BY-4.0 |
| [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml), Core ML conversion of [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) | speaker diarization | CC-BY-4.0 |
| [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml), from [Silero VAD](https://github.com/snakers4/silero-vad) | voice activity detection | MIT |

Meeting notes are written by Claude (Anthropic API) with the user's own API key; no model weights are involved.
