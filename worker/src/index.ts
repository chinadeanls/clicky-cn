/**
 * Clicky Proxy Worker
 *
 * Proxies TTS and legacy STT token requests so the app never ships raw API keys.
 * Chat/vision runs locally via pi-mono ai-server (Gemini), not through this worker.
 *
 * Routes:
 *   POST /tts   → ElevenLabs TTS API (bilingual zh+en via Flash v2.5)
 *   POST /transcribe-token → AssemblyAI streaming token
 */

interface Env {
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ELEVENLABS_TTS_MODEL?: string;
  ASSEMBLYAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const requestBodyText = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;
  const defaultModelId = env.ELEVENLABS_TTS_MODEL ?? "eleven_flash_v2_5";

  let requestBody = requestBodyText;
  try {
    const parsedBody = JSON.parse(requestBodyText) as Record<string, unknown>;
    if (typeof parsedBody.model_id !== "string" || parsedBody.model_id.trim() === "") {
      parsedBody.model_id = defaultModelId;
    }
    requestBody = JSON.stringify(parsedBody);
  } catch {
    // Pass through non-JSON bodies unchanged.
  }

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body: requestBody,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
