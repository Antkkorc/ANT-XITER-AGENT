import { useEffect, useMemo, useRef, useState } from 'react'
import {
  Camera,
  Check,
  CheckCircle2,
  CircleAlert,
  FileText,
  Info,
  LoaderCircle,
  LockKeyhole,
  Plus,
  RotateCcw,
  ScanLine,
  ShieldCheck,
  Sparkles,
  Trash2,
  Type,
  X,
} from 'lucide-react'
import { generateAnswers, type StudyAnswer } from '../lib/api'
import { recognizeFrame } from '../lib/ocr'

type CapturedPage = {
  id: string
  label: string
  text: string
}

type QuickAnswerProps = {
  apiReady: boolean | null
  onOpenSetup: () => void
}

const makeId = () => `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`

export default function QuickAnswer({ apiReady, onOpenSetup }: QuickAnswerProps) {
  const [cameraEnabled, setCameraEnabled] = useState(false)
  const [cameraReady, setCameraReady] = useState(false)
  const [cameraError, setCameraError] = useState('')
  const [cameraFacing, setCameraFacing] = useState<'environment' | 'user'>('environment')
  const [pages, setPages] = useState<CapturedPage[]>([])
  const [confirmed, setConfirmed] = useState(false)
  const [manualText, setManualText] = useState('')
  const [isScanning, setIsScanning] = useState(false)
  const [ocrLabel, setOcrLabel] = useState('Getting the page ready…')
  const [ocrProgress, setOcrProgress] = useState(0)
  const [scanNotice, setScanNotice] = useState('')
  const [scanError, setScanError] = useState('')
  const [isSolving, setIsSolving] = useState(false)
  const [answers, setAnswers] = useState<StudyAnswer[]>([])
  const [answerError, setAnswerError] = useState('')
  const streamRef = useRef<MediaStream | null>(null)
  const videoRef = useRef<HTMLVideoElement | null>(null)

  const allText = useMemo(() => pages.map((page) => page.text.trim()).filter(Boolean).join('\n\n'), [pages])
  const hasPageText = allText.trim().length > 0

  useEffect(() => {
    if (!cameraEnabled) return
    let mounted = true

    if (!navigator.mediaDevices?.getUserMedia) {
      setCameraError('Camera access is not available in this browser. Paste or type the questions below instead.')
      setCameraEnabled(false)
      return
    }

    setCameraError('')
    setCameraReady(false)
    navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        facingMode: { ideal: cameraFacing },
        width: { ideal: 1920 },
        height: { ideal: 1080 },
      },
    }).then((stream) => {
      if (!mounted) {
        stream.getTracks().forEach((track) => track.stop())
        return
      }
      streamRef.current = stream
      if (videoRef.current) videoRef.current.srcObject = stream
      setCameraReady(true)
    }).catch((error: unknown) => {
      if (!mounted) return
      const name = error instanceof DOMException ? error.name : ''
      if (name === 'NotAllowedError' || name === 'SecurityError') {
        setCameraError('Camera permission was blocked. Allow camera access in your browser settings, or use the text entry below.')
      } else if (name === 'NotFoundError') {
        setCameraError('No camera was found. Paste or type the questions below instead.')
      } else {
        setCameraError('Could not start the camera. Check that it is not being used by another app, or use text entry below.')
      }
      setCameraEnabled(false)
    })

    return () => {
      mounted = false
      streamRef.current?.getTracks().forEach((track) => track.stop())
      streamRef.current = null
      setCameraReady(false)
    }
  }, [cameraEnabled, cameraFacing])

  useEffect(() => {
    const handleProgress = (event: Event) => {
      const detail = (event as CustomEvent<{ status: string; progress?: number }>).detail
      if (detail?.status) setOcrLabel(detail.status === 'recognizing text' ? 'Reading text on your device…' : 'Preparing the local scanner…')
      if (typeof detail?.progress === 'number') setOcrProgress(Math.round(detail.progress * 100))
    }
    window.addEventListener('ant:ocr-progress', handleProgress)
    return () => window.removeEventListener('ant:ocr-progress', handleProgress)
  }, [])

  const stopCamera = () => {
    streamRef.current?.getTracks().forEach((track) => track.stop())
    streamRef.current = null
    setCameraEnabled(false)
    setCameraReady(false)
  }

  const scanPage = async () => {
    const video = videoRef.current
    if (!video || !cameraReady || !video.videoWidth) {
      setScanError('Wait for the camera preview to become clear, then try again.')
      return
    }

    setIsScanning(true)
    setConfirmed(false)
    setOcrProgress(0)
    setOcrLabel('Preparing the local scanner…')
    setScanError('')
    setScanNotice('')
    setAnswers([])
    setAnswerError('')

    const canvas = document.createElement('canvas')
    const scale = Math.min(1, 2000 / video.videoWidth)
    canvas.width = Math.round(video.videoWidth * scale)
    canvas.height = Math.round(video.videoHeight * scale)
    const context = canvas.getContext('2d', { willReadFrequently: true })

    if (!context) {
      setScanError('This browser could not prepare the camera frame. Try again or use text entry.')
      setIsScanning(false)
      return
    }

    context.filter = 'grayscale(1) contrast(1.12)'
    context.drawImage(video, 0, 0, canvas.width, canvas.height)

    try {
      const text = await recognizeFrame(canvas)
      setPages((current) => [
        ...current,
        { id: makeId(), label: `Page ${current.length + 1}`, text },
      ])
      setConfirmed(false)
      setScanNotice(text
        ? 'Page read on this device. Check the extracted text before asking for answers.'
        : 'No text was recognized. Move closer, improve the lighting, or paste the text below.')
    } catch {
      setScanError('The on-device OCR could not start. Check your connection once so the scanner can load, then try again—or use text entry.')
    } finally {
      canvas.width = 0
      canvas.height = 0
      setIsScanning(false)
    }
  }

  const updatePage = (id: string, text: string) => {
    setPages((current) => current.map((page) => page.id === id ? { ...page, text } : page))
    setConfirmed(false)
    setAnswers([])
    setAnswerError('')
  }

  const removePage = (id: string) => {
    setPages((current) => current.filter((page) => page.id !== id).map((page, index) => ({ ...page, label: `Page ${index + 1}` })))
    setConfirmed(false)
    setAnswers([])
    setAnswerError('')
  }

  const addManualPage = () => {
    const text = manualText.trim()
    if (!text) return
    setPages((current) => [...current, { id: makeId(), label: `Page ${current.length + 1}`, text }])
    setManualText('')
    setConfirmed(false)
    setAnswers([])
    setAnswerError('')
    setScanNotice('Text added. Review it, then confirm full-page coverage.')
  }

  const getAnswers = async () => {
    if (!confirmed || !allText.trim()) return
    setIsSolving(true)
    setAnswers([])
    setAnswerError('')
    try {
      const result = await generateAnswers(allText, 'study')
      setAnswers(result)
    } catch (error) {
      setAnswerError(error instanceof Error ? error.message : 'Could not generate answers. Please try again.')
    } finally {
      setIsSolving(false)
    }
  }

  return (
    <div className="quick-page">
      <section className="page-heading quick-heading">
        <div>
          <div className="eyebrow-row"><span className="eyebrow-dot" /> STUDY MODE <span className="heading-separator">/</span> CAMERA SCAN</div>
          <h1>Quick <span>answer.</span></h1>
          <p>Point your camera at a practice page. Review what was read, confirm the whole page is covered, then get a clear answer.</p>
        </div>
        <div className="privacy-pill"><ShieldCheck size={17} /><span>OCR stays on your device</span></div>
      </section>

      <div className="quick-grid">
        <section className="scanner-card panel-card" aria-label="Camera scanner">
          <div className="panel-heading">
            <div className="panel-title-group">
              <span className="step-number">01</span>
              <div><h2>Scan your page</h2><p>Keep the full question inside the frame.</p></div>
            </div>
            <span className={`scanner-status ${cameraReady ? 'is-live' : ''}`}><span />{cameraReady ? 'CAMERA LIVE' : 'READY TO SCAN'}</span>
          </div>

          <div className={`camera-stage ${cameraReady ? 'camera-on' : ''}`}>
            {cameraEnabled && <video ref={videoRef} className="camera-video" autoPlay muted playsInline aria-label="Live camera preview" />}
            {cameraEnabled && <div className="camera-shade" />}
            {cameraReady && <div className="scan-guide"><span /><span /><span /><span /></div>}
            {cameraReady && <div className="camera-overlay-label"><span className="overlay-live-dot" /> LIVE PREVIEW <span className="overlay-divider">·</span> NO PHOTO SAVED</div>}
            {!cameraReady && (
              <div className="camera-empty-state">
                <div className="camera-orbit"><Camera size={27} strokeWidth={1.6} /></div>
                <strong>{cameraError ? 'Camera unavailable' : 'A clear view makes all the difference'}</strong>
                <span>{cameraError || 'Hold the full page steady, with even light and no shadows.'}</span>
                {cameraError
                  ? <button className="button button-light camera-start-button" onClick={() => { setCameraError(''); setCameraEnabled(true) }}><Camera size={16} /> Try camera again</button>
                  : <button className="button button-light camera-start-button" onClick={() => setCameraEnabled(true)}><Camera size={16} /> Enable camera</button>}
              </div>
            )}
            {cameraReady && <div className="camera-bottom-hint"><span className="hint-dot" /> Center the whole page in the frame</div>}
            {isScanning && <div className="scanning-layer"><div className="scan-beam" /><div className="scanning-copy"><LoaderCircle className="spin" size={17} />{ocrLabel}<span>{ocrProgress ? `${ocrProgress}%` : 'Starting…'}</span></div></div>}
          </div>

          <div className="camera-controls">
            <div className="camera-help"><span className="camera-help-icon"><Info size={15} /></span><span>Every capture is processed in your browser. Images are not uploaded or saved.</span></div>
            <div className="camera-control-buttons">
              {cameraReady && <button className="icon-button" onClick={() => setCameraFacing((current) => current === 'environment' ? 'user' : 'environment')} aria-label="Switch camera" title="Switch camera"><RotateCcw size={17} /></button>}
              {cameraReady && <button className="icon-button stop-camera-button" onClick={stopCamera} aria-label="Turn camera off" title="Turn camera off"><X size={17} /></button>}
              <button className="button button-primary scan-button" disabled={!cameraReady || isScanning} onClick={() => void scanPage()}>
                {isScanning ? <><LoaderCircle className="spin" size={17} /> Scanning…</> : <><ScanLine size={17} /> Scan page</>}
              </button>
            </div>
          </div>
          {(scanError || scanNotice) && <div className={`scan-message ${scanError ? 'message-error' : ''}`} role={scanError ? 'alert' : 'status'}>
            {scanError ? <CircleAlert size={15} /> : <Check size={15} />}{scanError || scanNotice}
          </div>}
        </section>

        <section className="answers-card panel-card" aria-label="AI answers" aria-live="polite">
          <div className="panel-heading answers-heading">
            <div className="panel-title-group">
              <span className="step-number step-number-purple">03</span>
              <div><h2>Your answers</h2><p>Direct answer, with the reasoning.</p></div>
            </div>
            <span className="ai-card-badge"><Sparkles size={13} /> AI</span>
          </div>
          {answers.length > 0 ? (
            <div className="answer-results">
              <div className="results-summary"><CheckCircle2 size={16} /><span>{answers.length} {answers.length === 1 ? 'answer' : 'answers'} ready</span></div>
              {answers.map((item, index) => <AnswerCard answer={item} index={index} key={`${index}-${item.question}`} />)}
            </div>
          ) : answerError ? (
            <div className="answer-state answer-error-state">
              <span className="answer-state-icon error-icon"><CircleAlert size={20} /></span>
              <strong>Couldn’t get an answer</strong>
              <p>{answerError}</p>
              {!apiReady && <button className="text-link" onClick={onOpenSetup}>Open setup guide <span>→</span></button>}
            </div>
          ) : isSolving ? (
            <div className="answer-state">
              <span className="answer-state-icon loading-icon"><LoaderCircle className="spin" size={20} /></span>
              <strong>Working through the page…</strong>
              <p>Finding the questions and preparing clear explanations.</p>
              <div className="answer-loading-bar"><i /></div>
            </div>
          ) : (
            <div className="answer-state">
              <span className="answer-state-icon"><Sparkles size={20} /></span>
              <strong>Answers will appear here</strong>
              <p>Scan one or more pages, review the text, then confirm the full page to continue.</p>
              <div className="answer-lock-note"><LockKeyhole size={14} /> Results unlock after your coverage check</div>
            </div>
          )}
          <div className="answer-footer"><ShieldCheck size={14} /><span>Use answers to learn; follow your assessment rules.</span></div>
        </section>
      </div>

      <section className="review-card panel-card">
        <div className="review-topline">
          <div className="panel-title-group">
            <span className="step-number step-number-gold">02</span>
            <div><h2>Review &amp; confirm coverage</h2><p>Check the OCR, add another page if needed, then confirm you have scanned everything.</p></div>
          </div>
          <span className={`page-count ${pages.length ? 'has-pages' : ''}`}><FileText size={15} /> {pages.length} {pages.length === 1 ? 'page' : 'pages'}</span>
        </div>

        <div className="review-columns">
          <div className="captured-pages">
            {pages.length > 0 ? pages.map((page, index) => (
              <div className="captured-page" key={page.id}>
                <div className="captured-page-head">
                  <div className="captured-page-label"><span className="page-number-chip">{String(index + 1).padStart(2, '0')}</span><strong>{page.label}</strong><span className="ocr-tag">{page.text.trim() ? 'OCR text' : 'No text found'}</span></div>
                  <button className="remove-page-button" onClick={() => removePage(page.id)} aria-label={`Remove ${page.label}`} title="Remove page"><Trash2 size={15} /></button>
                </div>
                <textarea
                  className="ocr-textarea"
                  value={page.text}
                  onChange={(event) => updatePage(page.id, event.target.value)}
                  placeholder="No text detected. Type or paste the questions here."
                  aria-label={`Extracted text for ${page.label}`}
                  rows={Math.min(6, Math.max(3, page.text.split('\n').length))}
                />
              </div>
            )) : (
              <div className="no-pages-state"><div className="no-pages-icon"><ScanLine size={19} /></div><div><strong>No pages scanned yet</strong><span>Scan from the camera, or paste text below.</span></div></div>
            )}
            <details className="manual-entry">
              <summary><span><Type size={16} /> Paste or type text instead</span><Plus size={15} className="manual-plus" /></summary>
              <div className="manual-entry-body">
                <textarea value={manualText} onChange={(event) => setManualText(event.target.value)} placeholder="Paste a question or enter the text from your page…" rows={4} aria-label="Paste or type questions" />
                <button className="button button-outline add-text-button" onClick={addManualPage} disabled={!manualText.trim()}><Plus size={15} /> Add as page</button>
              </div>
            </details>
          </div>

          <div className="coverage-panel">
            <div className={`coverage-icon ${confirmed ? 'coverage-done' : ''}`}>{confirmed ? <Check size={20} /> : <ShieldCheck size={20} />}</div>
            <div className="coverage-copy">
              <strong>{confirmed ? 'Full page confirmed' : 'Did you scan the whole page?'}</strong>
              <span>{confirmed ? 'Answers are unlocked. Scan or edit a page to re-check coverage.' : 'If the app can’t tell where the page ends, you can confirm it yourself here.'}</span>
            </div>
            <button
              className={`button ${confirmed ? 'button-confirmed' : 'button-confirm'}`}
              onClick={() => { setConfirmed((value) => !value); setAnswers([]); setAnswerError('') }}
              disabled={!pages.length || !hasPageText || isSolving}
            >
              {confirmed ? <><Check size={16} /> Coverage confirmed</> : <><CheckCircle2 size={16} /> I’ve scanned the whole page</>}
            </button>
            <div className="coverage-footnote"><Info size={13} /><span>Review the text above. Confirm again after scanning or editing more pages.</span></div>
          </div>
        </div>

        <div className="review-actions">
          <div className="review-safety"><LockKeyhole size={14} /><span>Only the reviewed text is sent to AI when you continue.</span></div>
          <div className="solve-action-wrap">
            {!apiReady && <button className="setup-inline-link" onClick={onOpenSetup}>Connect Gemini</button>}
            <button className="button button-solve" onClick={() => void getAnswers()} disabled={!confirmed || !hasPageText || isSolving || apiReady === false}>
              {isSolving ? <><LoaderCircle className="spin" size={17} /> Thinking…</> : <><Sparkles size={17} /> Get answers</>}
            </button>
          </div>
        </div>
      </section>
      <div className="quick-bottom-note"><Info size={14} /><span>For study and practice use. Always follow your school or exam’s rules.</span></div>
    </div>
  )
}

type AnswerCardProps = { answer: StudyAnswer; index: number }

function AnswerCard({ answer, index }: AnswerCardProps) {
  return (
    <article className="answer-item">
      <div className="answer-item-top"><span className="answer-index">{String(index + 1).padStart(2, '0')}</span><span className="answer-label">ANSWER</span></div>
      {answer.question && answer.question !== 'Question' && <p className="answer-question">{answer.question}</p>}
      <p className="answer-main-text">{answer.answer}</p>
      {answer.explanation && <div className="answer-explanation"><span className="explanation-marker"><Sparkles size={12} /></span><p>{answer.explanation}</p></div>}
    </article>
  )
}
