#!/bin/zsh
# chat-scenarios.sh — what happens when a message arrives, against a running
# client, without asking anyone to send one.
#
#   Tools/chat-scenarios.sh [<account id>]
#
# Steam opens a chat window for every incoming message, and the popup that
# appears acks the message and suppresses Steam's own toast. Sevoflurane
# refuses the auto-open in both copies of the friends UI (SteamChatAutoOpen)
# and holds any chat window Steam shows unasked anyway (UnaskedChatPolicy).
# The scenarios below drive each half through Steam's own objects.
#
# The unit half of the same scenarios, which needs no client at all, is
# SevofluraneTests/IncomingChatTests.swift.
#
# Read-only apart from the windows it opens and closes: nothing here restarts
# the client, and no scenario writes to the bottle. The account id is any
# friend's 32-bit id; one is discovered from the friends store when omitted.

set -u

CONTROL=127.0.0.1:8764
SEVO=${SEVO:-sevo}
PASSED=0
FAILED=0

pass() { print -r -- "PASS  $1"; PASSED=$((PASSED + 1)) }
fail() { print -r -- "FAIL  $1"; print -r -- "      $2"; FAILED=$((FAILED + 1)) }
note() { print -r -- "      $1" }

# JavaScript in the app's own context page — the friends UI the user sees.
# `sevo eval` prints the bridge's JSON value, so a string arrives in quotes;
# the quotes come off so answers compare as words, the way `sevo cdp` prints.
page() { "$SEVO" eval "$1" 2>&1 | sed -E 's/^"(.*)"$/\1/' }
# JavaScript in the bottled client's SharedJSContext — its own second copy.
client() { "$SEVO" cdp "$1" 2>&1 }

log_since() {
    # The log lines written since the marker line count passed in $1.
    curl -s "$CONTROL/log/tail?n=4000" | tail -n +"$1"
}
log_lines() { curl -s "$CONTROL/log/tail?n=4000" | wc -l | tr -d ' ' }

visible_chat_count() {
    python3 - <<'PY'
import json, urllib.request
rows = json.load(urllib.request.urlopen("http://127.0.0.1:8764/windows"))
print(sum(1 for r in rows if r.get("role") == "chat" and r.get("visible")))
PY
}

# ---------------------------------------------------------------- preconditions

print -r -- "chat scenarios — against the client on $CONTROL"
print -r -- ""

STATUS=$(curl -s --max-time 5 "$CONTROL/status")
if [[ -z $STATUS ]]; then
    print -r -- "FAIL  the app is not answering on $CONTROL — start Sevoflurane first"
    exit 1
fi
if [[ $STATUS != *'"health":"healthy"'* ]]; then
    print -r -- "FAIL  the client is not healthy; scenarios need a signed-in client"
    print -r -- "      $STATUS"
    exit 1
fi
print -r -- "      client healthy"

ACCOUNT=${1:-}
if [[ -z $ACCOUNT ]]; then
    ACCOUNT=$(page '(function () {
      try {
        var ids = Array.from(
          window.g_FriendsUIApp.FriendStore.all_friends_accountids);
        return ids.length ? String(ids[0]) : "";
      } catch (e) { return ""; }
    })()')
fi
if [[ -z $ACCOUNT || $ACCOUNT == *[!0-9]* ]]; then
    print -r -- "FAIL  no friend account id — pass one: Tools/chat-scenarios.sh 37871103"
    exit 1
fi
print -r -- "      friend account id $ACCOUNT"
print -r -- ""

# --------------------------------------------- 1. the refusal is where it goes

ANSWER=$(page 'String(window.g_FriendsUIApp.BShowIncomingChatMessages())')
if [[ $ANSWER == false ]]; then
    pass "the app's friends UI refuses Steam the chat window for a message"
else
    fail "the app's friends UI refuses Steam the chat window for a message" \
         "BShowIncomingChatMessages() answered '$ANSWER', wanted 'false'"
fi

ANSWER=$(client 'String(window.g_FriendsUIApp.BShowIncomingChatMessages())')
if [[ $ANSWER == false ]]; then
    pass "the client's own friends UI refuses it too"
else
    fail "the client's own friends UI refuses it too" \
         "BShowIncomingChatMessages() answered '$ANSWER', wanted 'false'"
fi

# ------------------------------- 2. Steam's own show for a message opens nothing

# The exact call Steam's IncomingMessage handler makes, with the refusal
# stepped over: this is the backstop being tested, not the refusal.
BEFORE=$(log_lines)
ANSWER=$(page "(function () {
  var app = window.g_FriendsUIApp;
  var context = app.GetDefaultBrowserContext();
  var chat = app.ChatStore.GetFriendChat($ACCOUNT, true);
  if (!chat) return 'no chat for $ACCOUNT';
  app.UIStore.ShowAndOrActivateChat(context, chat, false);
  return 'shown';
})()")
sleep 2
if [[ $ANSWER != shown ]]; then
    fail "a chat Steam shows for a message stays off screen" "the page answered '$ANSWER'"
elif [[ $(visible_chat_count) == 0 ]]; then
    pass "a chat Steam shows for a message stays off screen"
    if log_since "$BEFORE" | grep -q "opened by an incoming message"; then
        note "the hold is in the log"
    else
        note "no hold line — Steam did not get as far as showing a window"
    fi
else
    fail "a chat Steam shows for a message stays off screen" \
         "$(curl -s $CONTROL/windows)"
fi

# ------------------------------------------- 3. the message stays unread

UNREAD=$(page "(function () {
  var chat = window.g_FriendsUIApp.ChatStore.GetFriendChat($ACCOUNT, false);
  return chat ? String(chat.GetVisibilityState()) : 'no chat';
})()")
# 0 is Steam's k_EChatVisibility for a chat with no popup — the state that
# keeps CheckShouldNotify from acking and OnReceivedNewMessage from skipping
# its toast. Anything at 4 is what the bug looked like.
if [[ $UNREAD == 4 ]]; then
    fail "the chat does not read as active" \
         "GetVisibilityState() is 4 (active): a message would be acked and its toast dropped"
else
    pass "the chat does not read as active (visibility state $UNREAD)"
fi

# -------------------------------------- 4. a message notification reaches macOS

# The payload the context page's NotificationStore subscription posts, pushed
# straight into the handler: everything downstream of Steam's store runs —
# decode, presentation, the macOS post, and the client's toast-twin sweep.
ID="sevo-scenario-$RANDOM"
BEFORE=$(log_lines)
ANSWER=$(page "(function () {
  window.webkit.messageHandlers.sevoWindow.postMessage({
    fn: '__steamNotification',
    args: [JSON.stringify({
      kind: 8, source: 1, id: '$ID',
      title: 'Chat scenarios', body: 'a message that nobody sent',
      icon: '', steamid: '', accountid: '$ACCOUNT', appid: '', gameName: ''
    })]
  });
  return 'posted';
})()")
sleep 2
COMPLAINT=$(log_since "$BEFORE" | grep "$ID")
if [[ $ANSWER != posted ]]; then
    fail "a message notification reaches macOS" "the page answered '$ANSWER'"
elif [[ -z $COMPLAINT ]]; then
    pass "a message notification reaches macOS"
    note "no drop, no hold, no post failure logged for $ID — look for the banner"
else
    fail "a message notification reaches macOS" "$COMPLAINT"
fi

# ------------------------------- 5. a friend starting a game is still presented

ID="sevo-scenario-$RANDOM"
BEFORE=$(log_lines)
page "(function () {
  window.webkit.messageHandlers.sevoWindow.postMessage({
    fn: '__steamNotification',
    args: [JSON.stringify({
      kind: 3, source: 1, id: '$ID',
      title: 'Chat scenarios', body: '', icon: '', steamid: '',
      accountid: '$ACCOUNT', appid: '', gameName: 'a game nobody owns'
    })]
  });
  return 'posted';
})()" > /dev/null
sleep 2
COMPLAINT=$(log_since "$BEFORE" | grep "$ID")
if [[ -z $COMPLAINT ]]; then
    pass "a friend starting a game is still presented"
else
    fail "a friend starting a game is still presented" "$COMPLAINT"
fi

# ---------------------------------- 6. a notification click opens the chat

# `/chat/open` is the call `SteamNotifications.handleClick` makes, so this is
# the click path with the banner taken out of it.
BEFORE=$(log_lines)
curl -s -X POST "$CONTROL/chat/open?accountid=$ACCOUNT" > /dev/null
sleep 3
if [[ $(visible_chat_count) -ge 1 ]]; then
    pass "a notification click opens the chat and shows it"
else
    fail "a notification click opens the chat and shows it" \
         "$(log_since "$BEFORE" | grep -i chat | tail -5)"
fi

# The window this scenario opened is a real one; put it away through Steam.
page "(function () {
  var app = window.g_FriendsUIApp;
  var steamid = String(BigInt($ACCOUNT) + BigInt('76561197960265728'));
  app.m_DesktopApp.ExecuteCommand(app.GetDefaultBrowserContext(),
    { command: 'CloseChatDialog', steamid: steamid });
  return 'closed';
})()" > /dev/null

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
[[ $FAILED == 0 ]]
