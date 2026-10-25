import { useEffect, useRef, useState } from 'react'
import {
  AudioLines,
  ArrowRight,
  Check,
  CircleAlert,
  ExternalLink,
  Info,
  LoaderCircle,
  Mic,
  MicOff,
  MessageSquareText,
  ShieldCheck,
  Sparkles,
  Square,
  Volume2,
} from 'lucide-react'
import { generateAnswers, type StudyAnswer } from '../lib/api'

type RecognitionResult = { isFinal: boolean; 0: { transcript: string } }
type RecognitionEvent = { resultIndex: number; results: ArrayLike<RecognitionResult> }
type RecognitionErrorEvent = { error: string }
type RecognitionLike = {
  lang: string
  continuous: boolean
  interimResults: boolean
  onresult: ((event: RecognitionEvent) => void) | null
  onerror: ((event: RecognitionErrorEvent) => void) | null
  onend: (() => void) | null
  start: () => void
  stop: () => void
}
type RecognitionConstructor = new () => RecognitionLike
type SpeechWindow = Window & { SpeechRecognition?: RecognitionConstructor; webkitSpeechRecognition?: RecognitionConstructor }

type LiveResponsesProps = {
  apiReady: boolean | null
  onOpenCompact: () => void
  compact: boolean
}

export default function LiveResponses({ apiReady, onOpenCompact, compact }: LiveResponsesProps) {
  const [isListening, setIsListening] = useState(false)
  const [transcript, setTranscript] = useState('')
  const [interim, setInterim] = useState('')
  const [speechError, setSpeechError] = useState('')
  const [isGenerating, setIsGenerating] = useState(false)
  const [answers, setAnswers] = useState<StudyAnswer[]>([])
  const [answerError, setAnswerError] = useState('')
  const recognitionRef = useRef<RecognitionLike | null>(null)

  useEffect(() => () => {
    recognitionRef.current?.stop()
  }, [])

  const startListening = () => {
    setSpeechError('')
    const speechWindow = window as SpeechWindow
    const Recognition = speechWindow.SpeechRecognition || speechWindow.webkitSpeechRecognition
    if (!Recognition) {
      setSpeechError('Live speech-to-text is not supported in this browser. You can still type or paste the question below.')
      return
    }

    try {
      const recognition = new Recognition()
      recognition.lang = 'en-US'
      recognition.continuous = true
      recognition.interimResults = true
      recognition.onresult = (event) => {
        let finalText = ''
        let interimText = ''
        for (let index = event.resultIndex; index < event.results.length; index += 1) {
          const item = event.results[index]
          if (!item) continue
          if (item.isFinal) finalText += item[0].transcript
          else interimText += item[0].transcript
        }
        if (finalText.trim()) {
          setTranscript((current) => `${current.trim()}${current.trim() ? ' ' : ''}${finalText.trim()}`)
          setAnswers([])
          setAnswerError('')
        }
        setInterim(interimText)
      }
      recognition.onerror = (event) => {
        setIsListening(false)
        if (event.error === 'not-allowed' || event.error === 'service-not-allowed') {
          setSpeechError('Microphone permission was blocked. Allow microphone access in your browser settings, or type the question below.')
        } else if (event.error === 'no-speech') {
          setSpeechError('No speech was heard. Check your microphone and try again.')
        } else {
          setSpeechError(`Speech recognition stopped (${event.error}). You can keep typing or paste a transcript.`)
        }
      }
      recognition.onend = () => {
        setIsListening(false)
        setInterim('')
      }
      recognitionRef.current = recognition
      recognition.start()
      setIsListening(true)
    } catch {
      setIsListening(false)
      setSpeechError('Could not start speech recognition. Try again, or type the question below.')
    }
  }

  const stopListening = () => {
    recognitionRef.current?.stop()
    recognitionRef.current = null
    setInterim('')
    setIsListening(false)
  }

  const suggestReply = async () => {
    const cleaned = transcript.trim()
    if (!cleaned) return
    if (isListening) stopListening()
    setIsGenerating(true)
    setAnswers([])
    setAnswerError('')
    try {
      setAnswers(await generateAnswers(cleaned, 'live'))
    } catch (error) {
      setAnswerError(error instanceof Error ? error.message : 'Could not suggest a response. Please try again.')
    } finally {
      setIsGenerating(false)
    }
  }

  return (
    <div className={`live-page ${compact ? 'live-page-compact' : ''}`}>
      {!compact && (
        <section className="page-heading live-heading">
          <div>
            <div className="eyebrow-row"><span className="eyebrow-dot live-eyebrow-dot" /> CONVERSATION MODE <span className="heading-separator">/</span> LIVE RESPONSES</div>
            <h1>Stay present.<br /><span>Find your words.</span></h1>
            <p>A low-distraction companion for practice conversations. Speak clearly, review the transcript, and ask for a suggested reply when you’re ready.</p>
          </div>
          <button className="button button-outline popout-button" onClick={onOpenCompact}><ExternalLink size={16} /> Open mini window</button>
        </section>
      )}

      <div className={`live-layout ${compact ? 'compact-live-layout' : ''}`}>
        {!compact && <div className="call-stage">
          <div className="call-stage-top"><span className="call-stage-kicker"><AudioLines size={15} /> YOUR CONVERSATION</span><span className="call-stage-tag">STAYS IN ITS OWN WINDOW</span></div>
          <div className="call-stage-visual">
            <div className="ambient-orb orb-one" /><div className="ambient-orb orb-two" />
            <div className="call-screen-icon"><Volume2 size={24} /></div>
            <span className="wave-line wave-a" /><span className="wave-line wave-b" />
            <strong>Keep your call in view</strong>
            <p>Place this window beside your call. ANT never opens, records, or captures the call itself.</p>
            <div className="call-caption"><span className="caption-dot" /> This page only uses your mic after you press Listen</div>
          </div>
          <div className="call-stage-footer"><ShieldCheck size={16} /><span>Mic on only when you choose. Tap Stop any time.</span></div>
        </div>}

        <section className="live-dock panel-card" aria-label="Live response assistant">
          <div className="dock-topbar">
            <div className="dock-brand"><span className="dock-brand-icon"><Sparkles size={17} /></span><div><strong>Response dock</strong><span>Live conversation helper</span></div></div>
            <div className={`listening-pill ${isListening ? 'listening-now' : ''}`}><span />{isListening ? 'LISTENING' : 'PAUSED'}</div>
          </div>

          <div className="dock-intro">
            <div className="dock-audio-icon"><AudioLines size={19} /></div>
            <div><strong>Catch the question, shape a reply.</strong><span>Tap listen, then review the transcript before sending it to AI.</span></div>
          </div>

          <div className="listen-controls">
            <button className={`listen-button ${isListening ? 'stop-listen' : ''}`} onClick={isListening ? stopListening : startListening}>
              {isListening ? <><Square size={15} fill="currentColor" /> Stop listening</> : <><Mic size={17} /> Start listening</>}
            </button>
            <div className={`audio-visualizer ${isListening ? 'visualizer-active' : ''}`} aria-label={isListening ? 'Microphone active' : 'Microphone inactive'}>
              {[8, 15, 10, 21, 12, 18, 7, 14, 20, 9, 16].map((height, index) => <i key={index} style={{ '--bar-height': `${height}px`, '--bar-delay': `${index * 0.09}s` } as React.CSSProperties} />)}
            </div>
          </div>
          <div className="mic-state-note"><span className={isListening ? 'mic-on-dot' : ''} />{isListening ? 'Microphone active — press Stop to end listening.' : 'Microphone off. Nothing is being listened to right now.'}</div>

          {(speechError || interim) && <div className={`speech-note ${speechError ? 'speech-note-error' : ''}`}>{speechError ? <CircleAlert size={14} /> : <AudioLines size={14} />}{speechError || `Hearing: ${interim}`}</div>}

          <label className="transcript-label" htmlFor="live-transcript"><span>TRANSCRIPT</span><span>{transcript.trim() ? `${transcript.trim().length} characters` : 'Edit before sending'}</span></label>
          <textarea
            id="live-transcript"
            className="live-transcript"
            value={transcript}
            onChange={(event) => { setTranscript(event.target.value); setAnswers([]); setAnswerError('') }}
            placeholder="Your speech transcript will appear here. You can also type or paste a question…"
            rows={compact ? 5 : 6}
          />

          <div className="dock-actions">
            <span className="transcript-private"><ShieldCheck size={14} /> Transcript stays here until you ask</span>
            <button className="button button-live-send" disabled={!transcript.trim() || isGenerating || apiReady === false} onClick={() => void suggestReply()}>
              {isGenerating ? <><LoaderCircle className="spin" size={16} /> Thinking…</> : <>Suggest reply <ArrowRight size={16} /></>}
            </button>
          </div>
          {!apiReady && <button className="live-setup-note" onClick={() => setAnswerError('Add GEMINI_API_KEY to the server environment before asking for AI replies. See the setup guide in README.md.')}>Google AI key needs setup <span>·</span> check README</button>}

          {(answers.length > 0 || answerError || isGenerating) && (
            <div className="live-reply-area" aria-live="polite">
              <div className="reply-divider"><span />SUGGESTED RESPONSE<span /></div>
              {isGenerating && <div className="live-answer-loading"><LoaderCircle className="spin" size={17} />Writing a thoughtful reply…</div>}
              {answerError && <div className="live-answer-error"><CircleAlert size={15} />{answerError}</div>}
              {answers.map((answer, index) => <LiveAnswer answer={answer} key={`${index}-${answer.question}`} />)}
            </div>
          )}

          <div className="dock-consent"><Info size={14} /><span>Ask other people before transcribing their speech. Browser speech services may process mic audio to create text.</span></div>
        </section>

        {!compact && <aside className="live-side-info">
          <div className="side-info-card">
            <div className="side-info-icon"><Info size={18} /></div>
            <strong>What this mode can—and can’t—do</strong>
            <p>This website can’t capture another app’s system audio or float above other apps. Use the mini window beside your call; speech recognition listens through your mic only after you start it.</p>
          </div>
          <div className="side-steps">
            <div className="side-steps-title">A clear, simple flow</div>
            <div className="side-step"><span>1</span><p>Start listening and let the question finish.</p></div>
            <div className="side-step"><span>2</span><p>Review or correct the transcript.</p></div>
            <div className="side-step"><span>3</span><p>Get a suggested reply when you’re ready.</p></div>
          </div>
        </aside>}
      </div>
    </div>
  )
}

type LiveAnswerProps = { answer: StudyAnswer }

function LiveAnswer({ answer }: LiveAnswerProps) {
  return (
    <article className="live-answer-card">
      <div className="live-answer-title"><span className="live-answer-check"><Check size={13} /></span><strong>{answer.question && answer.question !== 'Question' ? answer.question : 'Suggested reply'}</strong></div>
      <p className="live-answer-main">{answer.answer}</p>
      {answer.explanation && <p className="live-answer-reason">{answer.explanation}</p>}
    </article>
  )
}
