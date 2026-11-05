// Printer Hub relay. Pairs one home bridge with the owner's phones (per
// "room") and forwards sealed frames between them. It cannot read or forge
// them: the encryption key never leaves the bridge and the phones. Built for
// Cloudflare's free plan (SQLite Durable Objects, hibernating WebSockets).

export interface Env {
  ROOMS: DurableObjectNamespace;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === '/') return new Response('Printer Hub relay\n');
    const m = url.pathname.match(/^\/v1\/room\/([A-Za-z0-9_-]{16,64})$/);
    if (!m) return new Response('Not found', { status: 404 });
    if (req.headers.get('Upgrade') !== 'websocket') {
      return new Response('Expected a WebSocket', { status: 426 });
    }
    return env.ROOMS.get(env.ROOMS.idFromName(m[1])).fetch(req);
  },
};

async function sha256hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

type Who = { role: 'bridge' } | { role: 'app'; id: string };

const MAX_PHONES = 8;

export class Room {
  constructor(private state: DurableObjectState) {
    // Keep-alives are answered without waking the object (free-plan friendly).
    state.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  private bridge(except?: WebSocket): WebSocket | undefined {
    return this.state.getWebSockets('bridge').find((w) => w !== except);
  }

  private apps(): WebSocket[] {
    return this.state.getWebSockets('app');
  }

  private toApps(text: string) {
    for (const a of this.apps()) {
      try {
        a.send(text);
      } catch {
        // Closing socket; its close handler cleans up.
      }
    }
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const role = url.searchParams.get('role');
    const token = url.searchParams.get('token') ?? '';
    if ((role !== 'bridge' && role !== 'app') || token.length < 20) {
      return new Response('Bad request', { status: 400 });
    }
    const hash = await sha256hex(token);
    const stored = await this.state.storage.get<string>('tokenHash');
    if (!stored) {
      // An empty room is claimed by its bridge on first contact.
      if (role !== 'bridge') return new Response('This printer has not come online yet', { status: 404 });
      await this.state.storage.put('tokenHash', hash);
    } else if (stored !== hash) {
      return new Response('Forbidden', { status: 403 });
    }

    const [client, server] = Object.values(new WebSocketPair());
    if (role === 'bridge') {
      for (const old of this.state.getWebSockets('bridge')) {
        old.close(4000, 'Replaced by a newer bridge connection');
      }
      this.state.acceptWebSocket(server, ['bridge']);
      server.serializeAttachment({ role: 'bridge' } satisfies Who);
      this.toApps(JSON.stringify({ bridge: true }));
      // Phones that were already waiting get their sessions opened now.
      for (const app of this.apps()) {
        const who = app.deserializeAttachment() as Who;
        if (who.role === 'app') server.send(JSON.stringify({ c: who.id, open: true }));
      }
    } else {
      if (this.apps().length >= MAX_PHONES) {
        return new Response('Too many connections', { status: 429 });
      }
      const id = crypto.randomUUID().slice(0, 8);
      this.state.acceptWebSocket(server, ['app', `app:${id}`]);
      server.serializeAttachment({ role: 'app', id } satisfies Who);
      const bridge = this.bridge();
      server.send(JSON.stringify({ bridge: !!bridge }));
      bridge?.send(JSON.stringify({ c: id, open: true }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, msg: string | ArrayBuffer) {
    if (typeof msg !== 'string') return;
    const who = ws.deserializeAttachment() as Who;
    if (who.role === 'app') {
      this.bridge()?.send(JSON.stringify({ c: who.id, p: msg }));
      return;
    }
    // From the bridge: {"c": id, "p": frame} or {"c": id, "close": true}.
    let env: { c?: string; p?: unknown; close?: boolean };
    try {
      env = JSON.parse(msg);
    } catch {
      return;
    }
    const target = this.state.getWebSockets(`app:${env.c}`)[0];
    if (!target) return;
    if (env.close) target.close(1000, 'Closed by bridge');
    else if (typeof env.p === 'string') target.send(env.p);
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string) {
    this.gone(ws);
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }

  async webSocketError(ws: WebSocket) {
    this.gone(ws);
  }

  private gone(ws: WebSocket) {
    const who = ws.deserializeAttachment() as Who;
    if (who.role === 'app') {
      this.bridge()?.send(JSON.stringify({ c: who.id, close: true }));
    } else if (!this.bridge(ws)) {
      this.toApps(JSON.stringify({ bridge: false }));
    }
  }
}
