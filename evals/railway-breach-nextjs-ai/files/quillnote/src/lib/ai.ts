import OpenAI from "openai";
import Anthropic from "@anthropic-ai/sdk";

export const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
export const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

export async function draft(prompt: string) {
  const res = await anthropic.messages.create({
    model: "claude-sonnet-5-5",
    max_tokens: 1024,
    messages: [{ role: "user", content: prompt }],
  });
  return res.content;
}
