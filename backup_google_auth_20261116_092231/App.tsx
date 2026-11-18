import { useEffect, useRef, useState } from 'react'
import {
  Activity, ArrowLeftRight, Bell, BellRing, CheckCircle2, ChevronRight,
  CircleAlert, CreditCard, LayoutDashboard, LogOut, Shield, UserRound,
  Wallet, Zap, RefreshCw, Send, PlugZap
} from 'lucide-react'
import {
  getAuthStatus, registerGoogle, loginGoogle, setToken, getDashboard,
  saveAlertPreferences, getProfile, saveProfileCredentials, testTelegram,
  testExchange, logout
} from './api'

type Tab = 'home' | 'alerts' | 'settings' | 'exchange' | 'plan' | 'preferences' | 'profile' | 'exceptions'
type Dashboard = { exchange: string; mode: string; wallet_balance: number | null; open_positions: number; active_orders: number; unrealized_pnl: number | null; notice?: string }
type GoogleCredentialResponse = { credential: string }

const GOOGLE_CLIENT_ID = import.meta.env.VITE_GOOGLE_CLIENT_ID || ''

export default function App() {
  const [tab, setTab] = useState<Tab>('home')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [authState, setAuthState] = useState<'register'|'login'|'inactive'|'blocked'|'app'>('login')
  const [initData, setInitData] = useState('')
  const [name, setName] = useState('Trader')
  const [dashboard, setDashboard] = useState<Dashboard | null>(null)
  const [mode, setMode] = useState<'paper' | 'live'>('paper')
  const [registerMode, setRegisterMode] = useState<'paper'|'live'>('paper')
  const [confirmMode, setConfirmMode] = useState<'paper' | 'live' | null>(null)
  const [alertsEnabled, setAlertsEnabled] = useState(true)
  const [preferences, setPreferences] = useState({trading_alerts:true, exceptions:true, account_notifications:true})
  const [profile, setProfile] = useState<any>(null)
  const [apiKey, setApiKey] = useState('')
  const [apiSecret, setApiSecret] = useState('')
  const [telegramToken, setTelegramToken] = useState('')
  const [busy, setBusy] = useState(false)
  const [googleReady, setGoogleReady] = useState(false)
  const googleButton = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const init = async () => {
      try {
        const tg = window.Telegram?.WebApp
        if (!tg) {
          throw new Error('Telegram Web App could not be initialized.')
        }
        tg.ready()
        tg.expand()
        const telegramInitData = tg.initData
        if (!telegramInitData) {
          throw new Error(
            'Telegram authentication data is unavailable. Please reopen the Mini App from the bot.'
          )
        }
        setInitData(telegramInitData)
        const saved = sessionStorage.getItem('miniapp_session')
        if (saved) {
          setToken(saved)
          try {
            const data = await getDashboard()
            setDashboard(data); setMode(data.mode === 'LIVE' ? 'live' : 'paper')
            setAuthState('app')
            return
          } catch { setToken(''); sessionStorage.removeItem('miniapp_session') }
        }
        const status = await getAuthStatus(telegramInitData)
        if (status.status === 'unregistered') setAuthState('register')
        else if (status.status === 'inactive') setAuthState('inactive')
        else if (status.status === 'blocked') setAuthState('blocked')
        else setAuthState('login')
      } catch (e) { setError(e instanceof Error ? e.message : 'Unable to initialize') }
      finally { setLoading(false) }
    }
    void init()
  }, [])

  // Wait for Google Identity Services before trying to render its sign-in button.
  useEffect(() => {
    const scriptSelector = 'script[src="https://accounts.google.com/gsi/client"]'
    let script = document.querySelector<HTMLScriptElement>(scriptSelector)

    const markReadyIfAvailable = () => {
      if (window.google?.accounts?.id) {
        setGoogleReady(true)
        setError('')
        return true
      }
      return false
    }

    if (markReadyIfAvailable()) return

    // If the script tag is absent, add it dynamically.
    if (!script) {
      script = document.createElement('script')
      script.src = 'https://accounts.google.com/gsi/client'
      script.async = true
      script.defer = true
      document.head.appendChild(script)
    }

    const handleLoad = () => {
      if (!markReadyIfAvailable()) {
        setError('Google Sign-In loaded, but its identity service is unavailable.')
      }
    }

    const handleError = () => {
      setError('Unable to load Google Sign-In. Check the connection and reopen the Mini App.')
    }

    script.addEventListener('load', handleLoad)
    script.addEventListener('error', handleError)

    // Cover a script that completed between the initial check and listener setup.
    if (markReadyIfAvailable()) {
      script.removeEventListener('load', handleLoad)
      script.removeEventListener('error', handleError)
    }

    return () => {
      script?.removeEventListener('load', handleLoad)
      script?.removeEventListener('error', handleError)
    }
  }, [])

  useEffect(() => {
    if (
      loading ||
      authState === 'app' ||
      authState === 'inactive' ||
      authState === 'blocked' ||
      !googleButton.current ||
      !googleReady
    ) return

    if (!GOOGLE_CLIENT_ID) {
      setError('Google Sign-In is not configured. Set VITE_GOOGLE_CLIENT_ID in the frontend build environment.')
      return
    }

    googleButton.current.innerHTML = ''
    window.google.accounts.id.initialize({
      client_id: GOOGLE_CLIENT_ID,
      callback: async (response: GoogleCredentialResponse) => {
        setBusy(true); setError(''); setNotice('')
        try {
          if (authState === 'register') {
            const result = await registerGoogle(initData, response.credential, registerMode === 'paper')
            setNotice(result.message || 'Registration successful. Return to Telegram and press Login.')
            window.Telegram?.WebApp?.close?.()
          } else {
            const result = await loginGoogle(initData, response.credential)
            setName(result.user?.full_name || 'Trader')
            const data = await getDashboard()
            setDashboard(data); setMode(data.mode === 'LIVE' ? 'live' : 'paper')
            setAuthState('app')
          }
        } catch (e) { setError(e instanceof Error ? e.message : 'Google authentication failed') }
        finally { setBusy(false) }
      },
    })
    window.google.accounts.id.renderButton(googleButton.current, {theme:'filled_blue',size:'large',shape:'pill',text:'continue_with',width:280})
  }, [loading, authState, initData, registerMode, googleReady])

  useEffect(() => {
    if (authState !== 'app') return
    void getProfile().then(setProfile).catch(e => setError(e instanceof Error ? e.message : 'Unable to load profile'))
  }, [authState])

  const go = (next: Tab) => { window.Telegram?.WebApp?.HapticFeedback?.impactOccurred('light'); setTab(next); setError(''); setNotice('') }
  const saveExchange = async () => {
    if (!confirmMode) return
    setError('Exchange switching is currently disabled until active-order and active-position safety checks are connected.')
    setConfirmMode(null)
  }
  const saveCredentials = async () => {
    setBusy(true); setError(''); setNotice('')
    try {
      const result = await saveProfileCredentials({
        ...(apiKey ? {coindcx_api_key:apiKey} : {}),
        ...(apiSecret ? {coindcx_api_secret:apiSecret} : {}),
        ...(telegramToken ? {telegram_bot_token:telegramToken} : {}),
      })
      setProfile(result); setApiKey(''); setApiSecret(''); setTelegramToken('')
      setNotice('Profile credentials saved. Run the connectivity tests before enabling Live trading.')
    } catch (e) { setError(e instanceof Error ? e.message : 'Unable to save credentials') }
    finally { setBusy(false) }
  }
  const runConnectionTest = async (kind:'telegram'|'exchange') => {
    setBusy(true); setError(''); setNotice('')
    try {
      const result = kind === 'telegram' ? await testTelegram() : await testExchange()
      setNotice(result.message)
      setProfile(await getProfile())
    } catch (e) { setError(e instanceof Error ? e.message : `${kind} test failed`); setProfile(await getProfile().catch(() => profile)) }
    finally { setBusy(false) }
  }
  const doLogout = async () => { setBusy(true); try { await logout() } finally { window.Telegram?.WebApp?.close?.(); setBusy(false) } }

  if (loading) return <div className="center"><div className="spinner"/><p>Connecting securely…</p></div>
  if (error && authState !== 'app') return (<div className="center error-screen"><Shield size={38}/><h2>Unable to connect</h2><p>{error}</p><small>Please reopen the application from Telegram.</small></div>)
  if (authState === 'inactive' || authState === 'blocked') return <div className="center"><Shield size={38}/><h2>Account unavailable</h2><p>{authState === 'inactive' ? 'Your account is inactive.' : 'We could not safely identify your account.'} Please contact support.</p></div>
  if (authState === 'register' || authState === 'login') return <div className="center auth-screen">
    <div className="brand-mark"><Activity size={22}/></div><h1>{authState === 'register' ? 'Create your account' : 'Welcome back'}</h1>
    <p>{authState === 'register' ? 'Register with your verified Google account to start using AI Trading.' : 'Sign in with the Google account linked to your Telegram account.'}</p>
    {authState === 'register' && <div className="auth-mode"><b>Choose your exchange</b>
      <button className={registerMode==='paper'?'selected':''} onClick={() => setRegisterMode('paper')}><Shield size={18}/> Paper Exchange <span>Practice without exchange credentials</span></button>
      <button className={registerMode==='live'?'selected':''} onClick={() => setRegisterMode('live')}><Activity size={18}/> Live CoinDCX <span>Requires API credentials and successful connectivity test before live trading</span></button>
    </div>}
    {!GOOGLE_CLIENT_ID && <div className="notice warning">Google sign-in is not configured. Set VITE_GOOGLE_CLIENT_ID in the frontend build environment.</div>}
    <div ref={googleButton} className="google-button"/>
    {busy && <div className="spinner"/>}
    {error && <div className="notice warning">{error}</div>}
    {notice && <div className="notice">{notice}</div>}
    <small>Authentication uses Google verification and Telegram Mini App identity. No customer password is collected.</small>
  </div>

  if (!authState || authState !== 'app') return <div className="center"><p>Authentication required.</p></div>

  return <div className="app-shell">
    <header className="topbar">
      <div className="brand-mark"><Activity size={20}/></div>
      <div className="brand"><b>AI Trading</b><span>Trading workspace</span></div>
      <div className={`mode-pill ${mode}`}>{mode === 'paper' ? 'PAPER' : 'LIVE'}</div>
    </header>
    <main>
      {error && <div className="notice warning"><CircleAlert size={17}/><span>{error}</span></div>}
      {notice && <div className="notice"><CheckCircle2 size={17}/><span>{notice}</span></div>}
      {tab === 'home' && <section>
        <div className="greeting"><span>WELCOME BACK</span><h1>{name}</h1><p>Your trading overview at a glance.</p></div>
        <div className={`environment ${mode}`}><div className="env-top"><span>ACTIVE ENVIRONMENT</span><span className="live-dot"/></div><h2>{mode === 'paper' ? 'Paper Exchange' : 'Live CoinDCX'}</h2><p>{mode === 'paper' ? 'Simulated trading environment' : 'Real exchange account'}</p><button className="text-button" onClick={() => go('exchange')}>Manage exchange <ChevronRight size={16}/></button></div>
        <div className="section-heading"><h3>Account overview</h3><span>Current status</span></div>
        <div className="stats-grid"><Stat icon={<Wallet/>} label="Wallet balance" value={dashboard?.wallet_balance == null ? '—' : dashboard.wallet_balance.toLocaleString()}/><Stat icon={<Activity/>} label="Open positions" value={String(dashboard?.open_positions ?? '—')}/><Stat icon={<Zap/>} label="Active orders" value={String(dashboard?.active_orders ?? '—')}/><Stat icon={<Activity/>} label="Unrealized P&L" value={dashboard?.unrealized_pnl == null ? '—' : dashboard.unrealized_pnl.toLocaleString()}/></div>
        {dashboard?.notice && <div className="notice"><CircleAlert size={17}/><span>{dashboard.notice}</span></div>}
        <div className="section-heading"><h3>Quick access</h3></div><div className="quick-grid"><Quick icon={<Bell/>} title="Alerts" subtitle="Trading updates" onClick={() => go('alerts')}/><Quick icon={<CreditCard/>} title="Subscription" subtitle="Plan & validity" onClick={() => go('plan')}/><Quick icon={<ArrowLeftRight/>} title="Exchange" subtitle="Live or paper" onClick={() => go('exchange')}/><Quick icon={<UserRound/>} title="My profile" subtitle="Credentials & connectivity" onClick={() => go('profile')}/></div>
      </section>}
      {tab === 'alerts' && <Page title="Notification centre" subtitle="Stay informed about your trading activity"><MenuRow icon={<BellRing/>} title="Trading alerts" description="Signals, orders, positions, targets and stop losses" onClick={() => go('alerts')}/><MenuRow icon={<CircleAlert/>} title="Exceptions" description="Rejected orders, API failures and exchange issues" onClick={() => go('exceptions')}/><MenuRow icon={<Shield/>} title="Account notifications" description="Subscription, security and service messages" onClick={() => go('preferences')}/></Page>}
      {tab === 'exceptions' && <Page title="Exceptions" subtitle="Operational issues and important warnings"><div className="empty-state"><CheckCircle2 size={34}/><b>No exceptions displayed</b><p>Connect your notification event service to show account-specific exceptions here.</p></div></Page>}
      {tab === 'settings' && <Page title="Settings" subtitle="Manage your account and trading preferences"><MenuRow icon={<ArrowLeftRight/>} title="Choose exchange" description={`Currently using ${mode === 'paper' ? 'Paper Exchange' : 'Live CoinDCX'}`} onClick={() => go('exchange')}/><MenuRow icon={<CreditCard/>} title="Choose plan" description="View plans, limits and renewal date" onClick={() => go('plan')}/><MenuRow icon={<Bell/>} title="Enable alerts" description={alertsEnabled ? 'Notifications are enabled' : 'Notifications are paused'} onClick={() => go('preferences')}/><MenuRow icon={<UserRound/>} title="Profile" description="Credentials and connectivity tests" onClick={() => go('profile')}/><MenuRow icon={<LogOut/>} title="Logout" description="End this application session" onClick={() => void doLogout()}/></Page>}
      {tab === 'exchange' && <Page title="Choose exchange" subtitle="Select where your trading activity takes place"><div className={`choice-card ${mode === 'live' ? 'selected' : ''}`} onClick={() => setConfirmMode('live')}><div className="choice-icon live-icon"><Activity/></div><div className="choice-copy"><b>Live CoinDCX</b><span>Requires API key, API secret and successful connectivity test</span></div>{mode === 'live' && <CheckCircle2 className="selected-check"/>}</div><div className={`choice-card ${mode === 'paper' ? 'selected' : ''}`} onClick={() => setConfirmMode('paper')}><div className="choice-icon paper-icon"><Shield/></div><div className="choice-copy"><b>Paper Exchange</b><span>Simulated trading without exchange credentials</span></div>{mode === 'paper' && <CheckCircle2 className="selected-check"/>}</div>{confirmMode && <div className="confirm-box"><b>Exchange switching is currently protected</b><p>Switching remains disabled until active-order and active-position checks are implemented.</p><div className="button-row"><button className="btn-secondary" onClick={() => setConfirmMode(null)}>Close</button><button className="btn-primary" onClick={() => void saveExchange()}>Continue</button></div></div>}</Page>}
      {tab === 'plan' && <Page title="Subscription plan" subtitle="Your access and trading limits"><div className="plan-card"><span className="plan-label">CURRENT PLAN</span><h2>Connect your plan</h2><p>Plan name, validity, renewal and limits will be loaded from your subscription service.</p></div></Page>}
      {tab === 'preferences' && <Page title="Alert preferences" subtitle="Choose which updates you want to receive"><Toggle label="Trading alerts" description="Signals, orders and positions" value={preferences.trading_alerts} onChange={async v => { const next={...preferences,trading_alerts:v}; setPreferences(next); setAlertsEnabled(v); await saveAlertPreferences(next) }}/><Toggle label="Exceptions" description="Execution failures and exchange problems" value={preferences.exceptions} onChange={async v => { const next={...preferences,exceptions:v}; setPreferences(next); await saveAlertPreferences(next) }}/><Toggle label="Account notifications" description="Subscription and security updates" value={preferences.account_notifications} onChange={async v => { const next={...preferences,account_notifications:v}; setPreferences(next); await saveAlertPreferences(next) }}/></Page>}
      {tab === 'profile' && <Page title="My profile" subtitle="Manage optional exchange and Telegram integrations">
        <div className="profile-card"><div className="avatar">{(profile?.full_name || name).slice(0,1).toUpperCase()}</div><h2>{profile?.full_name || name}</h2><span>{profile?.email || ''}</span><small>Telegram ID: {profile?.telegram_chat_id || '—'}</small></div>
        <div className="profile-section"><h3><PlugZap size={17}/> CoinDCX exchange credentials</h3><p>Optional for registration and Paper Exchange. Required for Live trading.</p><label>API Key {profile?.coindcx_api_key_masked && <small>Saved: {profile.coindcx_api_key_masked}</small>}</label><input value={apiKey} onChange={e=>setApiKey(e.target.value)} placeholder="Enter CoinDCX API key" autoComplete="off"/><label>API Secret</label><input value={apiSecret} onChange={e=>setApiSecret(e.target.value)} placeholder="Enter CoinDCX API secret" type="password" autoComplete="new-password"/><div className="status-line"><span>Connectivity</span><b className={profile?.exchange_connection_status==='connected'?'status-ok':'status-pending'}>{profile?.exchange_connection_status || 'untested'}</b></div><button className="btn-secondary full" disabled={busy} onClick={()=>void runConnectionTest('exchange')}>Test CoinDCX connection</button></div>
        <div className="profile-section"><h3><Send size={17}/> Telegram bot connectivity</h3><p>Optional customer-owned Telegram bot. Start that bot from your Telegram account before testing delivery.</p><label>Customer Telegram Bot Token</label><input value={telegramToken} onChange={e=>setTelegramToken(e.target.value)} placeholder={profile?.telegram_bot_configured?'Token saved (enter new token to replace)':'Enter Telegram bot token'} type="password" autoComplete="new-password"/><div className="status-line"><span>Connectivity</span><b className={profile?.telegram_connection_status==='connected'?'status-ok':'status-pending'}>{profile?.telegram_connection_status || 'untested'}</b></div><button className="btn-secondary full" disabled={busy} onClick={()=>void runConnectionTest('telegram')}>Test Telegram connection</button></div>
        <button className="btn-primary full" disabled={busy || (!apiKey && !apiSecret && !telegramToken)} onClick={()=>void saveCredentials()}>{busy?'Please wait…':'Save credentials'}</button>
        <p className="muted-note">Secrets are never returned to the Mini App. Changing credentials invalidates the previous connectivity test. Live trading is blocked until the exchange test succeeds.</p>
      </Page>}
    </main>
    <nav className="bottom-nav"><NavButton active={tab === 'home'} icon={<LayoutDashboard/>} label="Home" onClick={() => go('home')}/><NavButton active={['alerts','exceptions'].includes(tab)} icon={<Bell/>} label="Alerts" onClick={() => go('alerts')}/><NavButton active={['settings','exchange','plan','preferences','profile'].includes(tab)} icon={<RefreshCw/>} label="Settings" onClick={() => go('settings')}/></nav>
  </div>
}

function Stat({icon,label,value}:{icon:React.ReactNode;label:string;value:string}) { return <div className="stat-card"><div className="stat-icon">{icon}</div><span>{label}</span><b>{value}</b></div> }
function Quick({icon,title,subtitle,onClick}:{icon:React.ReactNode;title:string;subtitle:string;onClick:()=>void}) { return <button className="quick-card" onClick={onClick}><span>{icon}</span><b>{title}</b><small>{subtitle}</small></button> }
function Page({title,subtitle,children}:{title:string;subtitle:string;children:React.ReactNode}) { return <section><button className="back-link" onClick={() => history.back()}>‹ Back</button><div className="page-heading"><h1>{title}</h1><p>{subtitle}</p></div><div className="page-content">{children}</div></section> }
function MenuRow({icon,title,description,onClick}:{icon:React.ReactNode;title:string;description:string;onClick?:()=>void}) { return <button className="menu-row" onClick={onClick}><span className="row-icon">{icon}</span><span className="row-copy"><b>{title}</b><small>{description}</small></span><ChevronRight size={18}/></button> }
function Toggle({label,description,value,onChange}:{label:string;description:string;value:boolean;onChange:(v:boolean)=>void}) { return <div className="toggle-row"><span><b>{label}</b><small>{description}</small></span><button className={`switch ${value?'on':''}`} onClick={() => onChange(!value)} aria-label={`Toggle ${label}`}><i/></button></div> }
function NavButton({active,icon,label,onClick}:{active:boolean;icon:React.ReactNode;label:string;onClick:()=>void}) { return <button className={`nav-button ${active?'active':''}`} onClick={onClick}>{icon}<span>{label}</span></button> }
