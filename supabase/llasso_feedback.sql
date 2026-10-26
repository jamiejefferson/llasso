-- Feedback sent from Llasso's menu bar. The app's publishable key may only add rows.
create table public.llasso_feedback (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  text text not null constraint llasso_feedback_text_len check (char_length(text) between 1 and 5000),
  feedback_type text not null default 'feedback' constraint llasso_feedback_type_check check (feedback_type in ('feedback', 'bug', 'feature')),
  app_version text,
  os_version text,
  email text constraint llasso_feedback_email_len check (email is null or char_length(email) <= 320),
  screenshot_b64 text constraint llasso_feedback_screenshot_size check (screenshot_b64 is null or char_length(screenshot_b64) <= 2000000),
  status text not null default 'new' constraint llasso_feedback_status_check check (status in ('new', 'in_progress', 'shipped', 'wont_fix')),
  shipped_version text
);

alter table public.llasso_feedback enable row level security;

-- No reading, changing or deleting with the public key.
revoke all on public.llasso_feedback from anon, authenticated;
grant insert on public.llasso_feedback to anon, authenticated;

create policy "anon can submit feedback" on public.llasso_feedback
  for insert to anon, authenticated with check (status = 'new' and shipped_version is null);
