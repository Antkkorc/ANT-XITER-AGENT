import { AudioLines, BookOpenCheck, ScanLine, Sparkles } from 'lucide-react'

export type AppView = 'quick' | 'live'

type SidebarProps = {
  activeView: AppView
  onNavigate: (view: AppView) => void
  compact?: boolean
}

export default function Sidebar({ activeView, onNavigate, compact = false }: SidebarProps) {
  if (compact) return null

  return (
    <aside className="sidebar">
      <button className="brand-lockup" onClick={() => onNavigate('quick')} aria-label="ANT Study home">
        <span className="brand-mark"><span>ANT</span><i /></span>
        <span className="brand-copy">
          <strong>ANT XITER</strong>
          <small>STUDY COMPANION</small>
        </span>
      </button>

      <div className="sidebar-section-label">YOUR WORKSPACE</div>
      <nav className="sidebar-nav" aria-label="Main navigation">
        <button
          className={`nav-link ${activeView === 'quick' ? 'active' : ''}`}
          onClick={() => onNavigate('quick')}
          aria-current={activeView === 'quick' ? 'page' : undefined}
        >
          <ScanLine size={18} strokeWidth={1.8} />
          <span>Quick answer</span>
          {activeView === 'quick' && <span className="nav-active-dot" />}
        </button>
        <button
          className={`nav-link ${activeView === 'live' ? 'active' : ''}`}
          onClick={() => onNavigate('live')}
          aria-current={activeView === 'live' ? 'page' : undefined}
        >
          <AudioLines size={18} strokeWidth={1.8} />
          <span>Live responses</span>
          <span className="nav-live-dot" title="Live responses" />
        </button>
      </nav>

      <div className="sidebar-separator" />
      <div className="sidebar-section-label">BUILT FOR LEARNING</div>
      <div className="sidebar-feature">
        <span className="feature-icon"><BookOpenCheck size={17} /></span>
        <div>
          <strong>Understand, not just copy</strong>
          <p>Get a clear answer with a short explanation.</p>
        </div>
      </div>

      <div className="sidebar-spacer" />
      <div className="sidebar-footer-note">
        <span className="footer-sparkle"><Sparkles size={14} /></span>
        <span>Made for practice papers<br />and thoughtful conversations.</span>
      </div>
      <div className="sidebar-profile">
        <div className="profile-avatar">A</div>
        <div className="profile-copy"><strong>Study space</strong><small>Personal workspace</small></div>
        <span className="profile-menu-dots">•••</span>
      </div>
    </aside>
  )
}
