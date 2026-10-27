declare module '@novnc/novnc/lib/rfb.js' {
  export default class RFB {
    constructor(target: HTMLElement, urlOrChannel: string | WebSocket, options?: { shared?: boolean; credentials?: { username?: string; password?: string } });
    scaleViewport: boolean;
    resizeSession: boolean;
    viewOnly: boolean;
    disconnect(): void;
    sendCredentials(credentials: { username?: string; password?: string }): void;
    addEventListener(type: string, listener: (event: CustomEvent) => void): void;
    removeEventListener(type: string, listener: (event: CustomEvent) => void): void;
  }
}
