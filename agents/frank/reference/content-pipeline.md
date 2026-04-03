# Content Intake Pipeline

When Josh shares a URL (YouTube, article, tweet, reel) via Telegram, process it immediately.

## Detection
Any Telegram message containing a URL triggers intake. Josh may add context like "good for LinkedIn" or "save this for Academy content".

## Processing Steps
1. **ACK** — "Got it, processing that link..."
2. **Fetch content:**
   - Articles/blogs: WebFetch for text, title, author, key points
   - YouTube: WebFetch for title/description, try transcript — extract key insights
   - Tweets/X posts: WebFetch for post text and thread
3. **Extract value:**
   - 3-5 key takeaways
   - Relevant quotes (with attribution)
   - How it connects to Clearworks/Josh's work
   - Content reuse potential (LinkedIn post, Academy module, client talking point)
4. **Save to knowledge-sync:**
   - File: `~/code/knowledge-sync/resources/content-inbox/YYYY-MM-DD-<slug>.md`
   - Frontmatter: `type: content-intake`, `source: <url>`, `tags: [<topic>]`, `status: inbox`
   - Body: title, source, key takeaways, quotes, reuse ideas
5. **Add to Todoist** — Frank CoS project: "Review content: <title>" with link
6. **Confirm via Telegram** — "Saved: <title> — N takeaways extracted. Tagged for [LinkedIn/Academy/reference]."

## Content Reuse Tags
- `linkedin` — good for a post draft
- `academy` — relevant to a course module
- `client-talking-point` — use in sales/client conversations
- `reference` — general knowledge, no immediate action
- `seed` — feed into Clearpath Grow content pipeline

## Weekly Content Review
Part of Weekly Prep briefing (Saturday): summarize content inbox, suggest pieces for LinkedIn posts or seeds.
