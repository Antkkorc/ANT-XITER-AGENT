# ANT XITER — study companion

A camera-first practice-paper scanner with a small live-conversation helper. Quick Answer reads a camera frame **in the browser**, asks you to check the extracted text, and keeps the answer button locked until you confirm that you scanned the whole page. Only the reviewed text is sent to Google AI when you request an answer.

## What’s included

- **Quick answer:** live camera preview, in-memory frame capture, local Tesseract OCR, editable OCR text, multi-page review, manual text entry, and an explicit full-page confirmation gate.
- **Live responses:** optional browser speech-to-text with visible start/stop controls, an editable transcript, and user-triggered reply suggestions.
- **Private-by-default API setup:** the Gemini key stays on the server and is never shipped to the browser.
- **Free-tier-friendly starting point:** Gemini Flash-Lite is the default model. Google’s free quota and model availability can change; check your AI Studio limits.
- **No database required:** nothing is saved to Supabase or a user account. Scan text and answers stay in page memory unless the user copies them.

## Run locally

Requirements: Node.js 20.19+ or 22.12+ and npm.

```bash
npm install
cp .env.example .env
```

Open `.env` and set a **new** Google AI Studio key:

```dotenv
GEMINI_API_KEY=your_new_key_here
GEMINI_MODEL=gemini-2.5-flash-lite
API_PORT=3001
```

Then start both the API and website:

```bash
npm run dev
```

Open the Vite address printed in the terminal (normally `http://localhost:5173`). Camera access requires `localhost` or HTTPS and browser permission. The development website proxies `/api` to the local Express API; browser code only makes same-origin requests.

If no API key is configured, scanning and text review still work, but AI answers remain disabled. The `.env` file is ignored by Git. **Never put the key in a `VITE_*` variable, frontend source file, or commit.**

## Data and browser limitations

- Camera frames are captured to an in-memory canvas for OCR and are not uploaded, stored, or added to the AI request. The first OCR run may download and cache Tesseract’s worker and English language data; OCR itself runs in the browser.
- When you choose **Get answers**, the OCR text is sent from the server to Google’s Gemini API. Google’s API terms and quota apply.
- Live speech recognition is opt-in and has a visible listening indicator and Stop button. Browser speech-recognition services may process microphone audio to produce a transcript. Ask other speakers for permission before transcribing them.
- A website cannot capture another application’s system audio or stay on top of other applications. **Open mini window** opens a regular, resizable browser window that you can place beside a call; it is not an always-on-top desktop overlay.
- Answers can be wrong. Use this for learning and practice, and follow the rules of any school, exam, or assessment.

## Deploy on Vercel (optional)

No Supabase account is needed. Vercel can serve the Vite build and the `api/answers.js` serverless function.

1. Import this repository into Vercel and keep the project root as the repository root.
2. Use the build command `npm run build` and output directory `dist` (also recorded in `vercel.json`).
3. Add `GEMINI_API_KEY` and, optionally, `GEMINI_MODEL` as **server-side** environment variables in the Vercel project settings. Do not use a `VITE_` prefix.
4. Redeploy, then open the site over HTTPS and allow camera/microphone access when you choose to use those features.

The API route validates request size and never returns the configured key. Free hosting and Gemini quotas are subject to each provider’s current limits.
