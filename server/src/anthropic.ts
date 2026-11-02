// The Claude request. The prompt lives here on the server so clients can't change it.

export const MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"] as const;
export const DEFAULT_MODEL = MODELS[0];
export const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

// Verbatim from AwwList/Scan/ClaudeScoring.swift (Claude.system); Swift line continuations joined.
export const SYSTEM_PROMPT = [
  `You rate family photos for "The Aww List", which ranks how cute the children in a family's photo library look.`,
  `Score 1 to 10 (one decimal allowed). Genuine emotion counts most (laughter, delight, sweetness, wonder), then connection between people, then the moment itself; sharpness and framing only break ties. Closed eyes, backs of heads and blur lose points; crying or tantrums score low. Use the whole scale: 5 is an ordinary nice photo, 8 is a favorite, 9 and 10 are rare, truly exceptional moments. Candid, unposed moments of kids having fun count in their favor, even when messy (food on faces, mud, wild hair) or imperfectly framed.`,
  `Leave the photo out (set "exclude") if: no child is the subject ("no_child"); a child is in a bath ("bath"), or undressed beyond a diaper, including shirtless children past the baby stage unless they're in swimwear at the beach, pool or splash pad ("undressed"); it is a screenshot, meme, document, collage, or a photo of a screen or print ("screenshot"); or it looks AI-generated or heavily edited or face-retouched ("ai_or_edited"). Swimsuits at the beach, pool or splash pad are fine: score those photos like any other and don't leave them out.`,
  `Reply with JSON only: {"score": number, "caption": "specific description of the moment, at most 8 words, no names", "exclude": null or one of the reasons above}`,
].join("\n");

export function messagesBody(model: string, image: string): string {
  return JSON.stringify({
    model,
    max_tokens: 2000,
    system: SYSTEM_PROMPT,
    output_config: { effort: "low" },
    messages: [
      {
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: "image/jpeg", data: image } },
          { type: "text", text: "Rate this photo." },
        ],
      },
    ],
  });
}

export function callClaude(apiKey: string, model: string, image: string): Promise<Response> {
  return fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: messagesBody(model, image),
  });
}
