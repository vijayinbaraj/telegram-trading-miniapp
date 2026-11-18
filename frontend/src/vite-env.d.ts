/// <reference types="vite/client" />
interface Window {
  Telegram?: { WebApp?: {
    initData: string; ready():void; expand():void; close():void;
    HapticFeedback?: {impactOccurred(style:'light'|'medium'|'heavy'):void}
  }}
}

interface Window { google?: any }
