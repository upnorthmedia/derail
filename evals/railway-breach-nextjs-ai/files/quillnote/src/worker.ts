import PgBoss from "pg-boss";
import { draft } from "./lib/ai";
import { Resend } from "resend";

const boss = new PgBoss(process.env.DATABASE_URL!);
const resend = new Resend(process.env.RESEND_API_KEY);

await boss.start();
await boss.work("draft", async ([job]) => {
  const out = await draft((job.data as { prompt: string }).prompt);
  await resend.emails.send({ from: "drafts@quillnote.example", to: (job.data as { to: string }).to, subject: "Your draft", text: JSON.stringify(out) });
});
