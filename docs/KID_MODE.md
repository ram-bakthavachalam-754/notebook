# Kid mode (one device)

Kid mode turns the agent into **Ask**, a curiosity guide for a child, and
hides the apps a parent turned off. It is built from the
[family controls design](family/design.html): the rules and checks, the
parent's Family editor, and joining a family with a signed rules file. The
signed file reaches the child's device through iCloud, or by hand.

## What the child gets

- **Ask** instead of the Agent: a "Wonder of the day", starter questions by
  subject, "Surprise me", and two follow-up buttons under each answer.
- Only the apps the policy turns on: Notes, Journal, Ask and Money by default;
  Links and Documents if turned on. Finance tracks investments, so kids never
  see it.
- **Note templates** (if on): New Note offers I wonder, Reading log, Big idea
  and Checklist. A template note is saved only once the child types in it.
- **Evening journal reminder** (if set): a daily local notification at the
  parent's time, after the child allows notifications.
- **Money**: savings goals with + $1 and + $5 (and Take Out in the ⋯ menu),
  capped at the goal, and the weekly allowance the parent set. Money is
  counted, never moved: the allowance is handed over at home. Goals sync
  between the child's own devices. Ask can read the goals but not change them.
- No rules, topics or versions anywhere. A blocked question gets the parent's
  message as an ordinary reply. Agent settings are locked.

## How a question is handled

1. **On the device:** quiet hours and the daily question limit.
2. **Question check:** a separate call to the AI with only the rules, the
   child's age and the question (no chat history, no tools). It returns
   allow, careful, block, homework or crisis. Homework and crisis get fixed
   replies; a matching parent rule or a blocked topic gets the parent's message
   and the agent is never called.
3. **The agent** runs with the child's instructions added, and only the tools
   for the child's apps (no web unless allowed, no finance, writes only to
   notes and journal). Calls to anything else are rejected in code.
4. **Answer check:** the finished answer is checked before it's shown; one that
   fails is replaced with the parent's message. Live typing is off, so nothing
   unchecked ever appears or is saved.

If a check can't run or returns anything unexpected, the question isn't
answered: "I couldn't check that question. Try again in a moment."

The logic is in `js/agent/agent-policy.js` (tests in
`tests/agent-policy.test.js`) and `ios/Notebook/AgentModel.swift`.

## Setting up a child's device

1. **On your Mac or iPhone:** Settings → Family → Add a Child. Choose the apps
   (with templates, the journal reminder and the allowance), topics, how Ask
   answers, your rules, the AI connection (with a key), and tools and time.
   Profiles live in your notebook and sync between your devices.
2. **Add a Device…** in the child's profile shows a QR code, a code to copy and
   a 6-digit number. The code expires in 10 minutes.
3. **On the child's device:** Settings → Family → "Is this your child's
   device?" Scan the code (iPhone) or paste it (Mac). Check that it shows the
   same number. From then on the device accepts only rules you sign.
4. **Publish to [name]…** saves the rules file at the next version. In
   signed builds with iCloud on, it's also sent through iCloud, and the
   child's device installs it on its next sync (within about a minute). Without
   iCloud, on the child's device: Settings → Family → **Install Rules File…**
   The list on your device shows unpublished changes per child and whether the
   last publish reached iCloud.

**Release Devices…** saves a signed file that turns kid mode off and leaves the
family; install it the same way.

### How the rules are protected

The rules file is encrypted with the child's family key (AES-GCM) and signed
with your parent key (Ed25519), which lives in your notebook. The device
checks the signature against the parent it joined, refuses a version at or
below the installed one, and checks that the rules inside are for this child
at that version. The family key and your public key reach the device only
through the join code. A device a parent manages can't join another family.
The code is in `native/Sources/NotebookCore/FamilyPolicy.swift`, with tests in
`native/Tests/NotebookCoreTests/FamilyPolicyTests.swift`.

The AI key goes into the device's keychain; the rest of the policy into the
app's settings on that device. Neither is synced.

Use a separate API key for each child, with a monthly spending cap at the
provider. The model must accept images, because attached photos are checked
too.

### Testing with an unsigned file

Debug builds also install a plain, unsigned policy on a device that hasn't
joined a family (Mac: `--install-policy <file>`; iPhone: Settings → Family →
Install Unsigned Rules File…). For example `sam.json`:

```json
{
  "schema": 1, "version": 1, "child": "sam", "name": "Sam", "age": 9, "parentName": "Dad",
  "style": "wonder",
  "rules": ["No video game cheats or hacks"],
  "refusal": "That's a good one to ask Dad about. Want to wonder about something else?",
  "connection": { "provider": "anthropic", "model": "claude-haiku-5-5", "apiKey": "sk-ant-…" },
  "tools": { "web": false, "editNotes": true },
  "limits": { "messagesPerDay": 40, "quietHours": ["21:00", "07:00"] },
  "apps": { "notes": { "on": true, "templates": true }, "journal": { "on": true, "reminder": "19:30" },
            "agent": { "on": true }, "money": { "on": true, "allowance": 5 }, "links": { "on": false } },
  "attach": { "library": true, "files": false }
}
```

Topics default to the age's preset (under 10, 10–13, teen); override any with
`"topics": { "scary": "careful" }` using allow, careful or block. To leave kid
mode, install `{ "schema": 1, "version": <higher>, "managed": false }`.

Try this on a test copy (`NOTEBOOK_DATA_ROOT`) or a child's own account: the
policy applies to the whole app on that Mac user or iPhone.

## Sharing

Each child's Apps settings have a Sharing choice: Nobody, Family only (the
default) or Anyone on Notebook. Children share notes and links collections
only, never Finance. Family only means the Apple Account emails you list
under it: the child can add only those people to a share, and accepts
invitations only from them. Accepting needs the owner's email to be visible
to Notebook; when iCloud doesn't provide it, a Family only child can't accept
and sees that a parent's setting doesn't allow it.

## Not built yet

Rotating a family key to remove one device: release the child and add their
devices again. Device status rows (which devices installed which version).

iCloud delivery is built but untested: it needs a signed parent build and a
signed child build on separate Apple Accounts. It uses a `FamilyPolicy`
record type in the public database of the Notebook container (fields
`envelope`, `signature`, `version`; record name = policy ID). A Development
build creates the type on its first publish; deploy the schema to Production
in the CloudKit Console before TestFlight. Keep the default security roles:
anyone can read, only the creator can write. The rules file still works when
iCloud doesn't. Money's "accounts and
spending" mode from the design isn't planned, since spending was removed.
