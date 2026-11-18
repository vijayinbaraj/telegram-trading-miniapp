const API = import.meta.env.VITE_API_BASE_URL || ''
let token = ''
export function setToken(value: string) { token = value }

async function request<T>(path: string, init: RequestInit = {}, authenticated = true): Promise<T> {
  const response = await fetch(`${API}${path}`, {
    ...init,
    headers: {'Content-Type':'application/json', ...(authenticated && token ? {Authorization:`Bearer ${token}`} : {}), ...(init.headers || {})},
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) {
    const detail = body?.detail
    throw new Error(typeof detail === 'string' ? detail : `API request failed (${response.status})`)
  }
  return body as T
}

export const getAuthStatus = (initData: string) =>
  request<{status:'unregistered'|'login'|'inactive'|'blocked';authenticated:boolean}>('/miniapp/auth/status', {
    method:'POST', body:JSON.stringify({init_data:initData}),
  }, false)

export const registerGoogle = (initData:string, credential:string, paperTesting:boolean) =>
  request<any>('/miniapp/register', {method:'POST',body:JSON.stringify({init_data:initData,credential,paper_testing:paperTesting})}, false)

export async function loginGoogle(initData:string, credential:string) {
  const result = await request<{access_token:string;user:any}>('/miniapp/login', {
    method:'POST',body:JSON.stringify({init_data:initData,credential}),
  }, false)
  setToken(result.access_token)
  sessionStorage.setItem('miniapp_session', result.access_token)
  return result
}

export const logout = async () => {
  try { await request('/miniapp/logout',{method:'POST',body:'{}'}) }
  finally { setToken(''); sessionStorage.removeItem('miniapp_session') }
}
export const getDashboard = () => request<any>('/miniapp/dashboard')
export const getSettings = () => request<any>('/miniapp/settings')
export const getAlerts = () => request<any>('/miniapp/alerts')
export const getExceptions = () => request<any>('/miniapp/exceptions')
export const getProfile = () => request<any>('/miniapp/profile')
export const saveProfileCredentials = (payload:{coindcx_api_key?:string;coindcx_api_secret?:string;telegram_bot_token?:string}) =>
  request<any>('/miniapp/profile/credentials',{method:'PUT',body:JSON.stringify(payload)})
export const testTelegram = () => request<any>('/miniapp/profile/test-telegram',{method:'POST',body:'{}'})
export const testExchange = () => request<any>('/miniapp/profile/test-exchange',{method:'POST',body:'{}'})
export const saveAlertPreferences = (preferences:Record<string,boolean>) =>
  request<any>('/miniapp/settings/alerts',{method:'PUT',body:JSON.stringify(preferences)})
export const changeExchange = () => request<any>('/miniapp/exchange',{method:'POST',body:JSON.stringify({})})
