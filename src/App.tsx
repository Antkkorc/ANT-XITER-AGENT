import { useCallback, useEffect, useState } from 'react'
import { Activity, ArrowUpRight, Check, CircleHelp, KeyRound, Sparkles, X } from 'lucide-react'
import Sidebar, { type AppView } from './components/Sidebar'
import QuickAnswer from './components/QuickAnswer'
import LiveResponses from './components/LiveResponses'
import { getApiStatus, type ApiStatus } from './lib/api'

const initialView: AppView = new URLSearchParams(window.location.search).get('view') === 'live' ? 'live' : 'quick'
const isCompactWindow = new URLSearchParams(window.location.search).get('compact') === '1'

export default function App() {
  const [activeView, setActiveView] = useState<AppView>(initialView)
  const [apiStatus, setApiStatus] = useState<ApiStatus | null>(null)
  const [setupOpen, setSetupOpen] = useState(false)

  const refreshStatus = useCallback(async () => {
    try {
      const status = await getApiStatus()
      setApiStatus(status)
    } catch {
      setApiStatus({ ready: false, provider: 'Google AI Studio', model: '' })
    }
  }, [])

  useEffect(() => {
    void refreshStatus()
    const interval = window.setInterval(() => void refreshStatus(), 20_000)
    return () => window.clearInterval(interval)
  }, [refreshStatus])

  const openCompactWindow = () => {
    const url = `${window.location.origin}${window.location.pathname}?view=live&compact=1`
    const popup = window.open(url, 'ant-live-responses', 'popup,width=430,height=760,resizable=yes,scrollbars=yes')
    if (!popup) {
      window.alert('Your browser blocked the pop-out. Allow pop-ups for this site, then try again.')
    }
  }

  return (
    <div className={`app-shell ${isCompactWindow ? 'compact-app' : ''}`}>
      {!isCompactWindow && <Sidebar activeView={activeView} onNavigate={setActiveView} />}
      <main className="app-main">
        {!isCompactWindow && (
          <header className="topbar">
            <div className="breadcrumbs">
              <span>Workspace</span><span className="crumb-slash">/</span>
              <strong>{activeView === 'quick' ? 'Quick answer' : 'Live responses'}</strong>
            </div>
            <div className="topbar-actions">
              <button className="ai-status-button" onClick={() => setSetupOpen(true)} aria-label="AI connection setup">
                <span className={`status-pulse ${apiStatus?.ready ? 'is-ready' : ''}`} />
                <span>{apiStatus?.ready ? 'Gemini connected' : apiStatus === null ? 'Checking AI' : 'AI setup needed'}</span>
                {apiStatus?.ready && <Check size={14} />}
                {!apiStatus?.ready && <KeyRound size={14} />}
              </button>
              <button className="top-help-button" onClick={() => setSetupOpen(true)} aria-label="Help and setup"><CircleHelp size={18} /></button>
              <div className="top-avatar" aria-label="Study space">A</div>
            </div>
          </header>
        )}

        <div className={`app-content ${isCompactWindow ? 'compact-content' : ''}`}>
          {!isCompactWindow && activeView === 'quick' && <QuickAnswer apiReady={apiStatus?.ready ?? null} onOpenSetup={() => setSetupOpen(true)} />}
          {!isCompactWindow && activeView === 'live' && <LiveResponses apiReady={apiStatus?.ready ?? null} onOpenCompact={openCompactWindow} compact={false} />}
          {isCompactWindow && <LiveResponses apiReady={apiStatus?.ready ?? null} onOpenCompact={openCompactWindow} compact />}
        </div>
      </main>

      {setupOpen && <SetupModal onClose={() => setSetupOpen(false)} />}
    </div>
  )
}

type SetupModalProps = { onClose: () => void }

function SetupModal({ onClose }: SetupModalProps) {
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose() }}>
      <section className="setup-modal" role="dialog" aria-modal="true" aria-labelledby="setup-title">
        <button className="modal-close" onClick={onClose} aria-label="Close setup"><X size={18} /></button>
        <div className="modal-icon"><Sparkles size={22} /></div>
        <p className="eyebrow">ONE-TIME SETUP</p>
        <h2 id="setup-title">Connect Google AI</h2>
        <p className="modal-intro">The scanner runs OCR in your browser. Only the recognized text is sent to Google AI when you ask for an answer.</p>
        <div className="setup-steps">
          <div><span>01</span><p>Create a fresh Gemini API key in Google AI Studio.</p></div>
          <div><span>02</span><p>Copy <code>.env.example</code> to <code>.env</code>, then set <code>GEMINI_API_KEY</code>.</p></div>
          <div><span>03</span><p>Restart the app. Keep the key server-side—never add it to browser code or commit it.</p></div>
        </div>
        <div className="setup-safe-note"><Activity size={16} /><span>No Supabase account is needed. Google AI Studio quotas and free-tier limits can change.</span></div>
        <a className="setup-doc-link" href="https://aistudio.google.com/app/apikey" target="_blank" rel="noreferrer">
          Open Google AI Studio <ArrowUpRight size={15} />
        </a>
      </section>
    </div>
  )
}
