---
id: t-d25e68cc
title: Vision heads-up: detect Ollama model vision capability via /api/show (close the local-model blind spot)
status: done
added: 2026-07-14
---

## Description

Live dogfood 2026-07-14 (Alan): the t-31img composer heads-up did NOT fire for llama3.1:8b + image attachment because local Ollama models are absent from models.dev → VisionCapability resolves .unknown → no warning by design (to avoid false-warning llama3.2-vision). Result: the feature is silent for exactly the local-model audience most likely to attach images to a non-vision model and get Hermes's confusing lossy vision_analyze/"paid subscription" text-pipeline response (screenshot confirms). FIX (nearly free): Ollama's POST /api/show returns a "capabilities" array that includes "vision" for multimodal models — and LocalModelEnumerator ALREADY calls /api/show per model for context_length (commit 89107d2), so vision detection piggybacks on the existing batch call with zero extra round-trips. Wire: enumerator surfaces per-Ollama-model vision capability → RichChatViewModel's hint decision treats a confirmed-non-vision LOCAL model as .no (warn), keeping .unknown only for truly-unknown endpoints (LM Studio/custom without the field). VERIFY the /api/show capabilities shape against the live daemon first (Ollama version-dependent). Also consider surfacing it in the picker (a "vision" badge on capable local models). Scope: LocalModelEnumerator, RichChatViewModel, maybe ModelPickerSheet. Risk: LOW (additive).

## Plan



## Artifacts



