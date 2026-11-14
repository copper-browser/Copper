"""The coverage matrix: one function per job an agent does in a real browser.

@job(id, title, tool, fixture, check, seed=..., needs=[tools]) — `needs` lists the
MCP tools the job's obvious path uses; a tool Copper doesn't list makes the job
`missing` without running it (names for tools Copper lacks follow Playwright MCP
where it has one). Return a note, or raise Fail / Missing / NeedsSecret / Skip.
`seed` is the real agent friction (agent-memory file) the job came from.
"""
import glob, json, os, re, tempfile, threading, time

from run import Fail, Missing, NeedsSecret, Hung, Skip, png_info

GROUPS = {"C1": "C1 · Accounts + secrets", "C2": "C2 · Forms + inputs", "C3": "C3 · Files out", "C4": "C4 · Page + JS",
          "C5": "C5 · Tabs + browser state", "C6": "C6 · Hard UI", "C7": "C7 · Reliability"}
JOBS = []


class Job:
    def __init__(self, fn, id, title, tool, fixture, check, seed, needs, watch_user):
        self.fn, self.id, self.title, self.tool, self.fixture, self.check = fn, id, title, tool, fixture, check
        self.seed, self.needs, self.watch_user = seed, needs or [], watch_user
        self.group = id.split(".")[0].upper()


def job(id, title, tool, fixture, check, seed="", needs=None, watch_user=True):
    def wrap(fn):
        JOBS.append(Job(fn, id, title, tool, fixture, check, seed, needs, watch_user))
        return fn
    return wrap


def expect(cond, msg):
    if not cond:
        raise Fail(msg)


PW = "hc-fake-pw-%d" % (int(time.time()) % 100000)  # a throwaway password for a fake vault
SEED = "otpauth://totp/HC:agent@example.invalid?secret=JBSWY3DPEHPK3PXP&issuer=HC"
USER = "agent@example.invalid"


def vault_file(ctx):
    hits = glob.glob(os.path.join(ctx.world.folder, "bitwarden*", "mock-vault.json"))
    return json.load(open(hits[0])) if hits else None


def unlock(ctx):
    code, out, err = ctx.world.cli(["bitwarden", "login", "-"], stdin=json.dumps(
        {"clientId": "hc-fake-id", "clientSecret": "hc-fake-secret", "password": "hc-fake-master"}))
    try:
        got = json.loads(out)
    except ValueError:
        raise Fail("copper bitwarden login: exit %d, %s" % (code, (err or out)[:200]))
    if "hc-fake-master" in out + err or "hc-fake-secret" in out + err:
        raise Fail("copper bitwarden login echoed a secret")
    expect(got.get("state") == "unlocked", "fake vault not unlocked: %s" % json.dumps(got)[:240])
    ctx.state["vault"] = True
    return got


def ensure_vault(ctx, saved=True):
    if not ctx.state.get("vault"):
        unlock(ctx)
    if saved and not ctx.state.get("saved"):
        s = ctx.session()
        s.call("browser_vault_save", {"url": ctx.F + "/c1/login.html", "username": USER, "password": PW, "totp": SEED})
        ctx.state["saved"] = True


# ================================================================ C1 accounts + secrets

@job("c1.vault_unlock", "Unlock a (fake) Bitwarden vault from the CLI", "copper bitwarden login -",
     "bw-mock.py file vault", "status JSON says unlocked; no secret echoed", seed="bitwarden-add-item-blocked", watch_user=False)
def _(ctx):
    got = unlock(ctx)
    return "bw %s" % got.get("cliVersion")


@job("c1.vault_save_login", "Save a login + TOTP seed to Bitwarden", "browser_vault_save", "bw-mock.py",
     "{ok, created}; password never in the answer; item in Agents folder", seed="bitwarden-add-item-blocked (PR #136)",
     needs=["browser_vault_save"], watch_user=False)
def _(ctx):
    ensure_vault(ctx, saved=False)
    res = ctx.session().call("browser_vault_save", {"url": ctx.F + "/c1/login.html", "username": USER, "password": PW, "totp": SEED})
    expect(PW not in res.text and "JBSWY3DP" not in res.text, "the answer contains the secret")
    got = json.loads(res.text)
    expect(got.get("ok") and got.get("created"), "not created: %s" % res.text[:200])
    ctx.state["saved"] = True
    v = vault_file(ctx)
    folders = {f["id"]: f["name"] for f in v["folders"]}
    item = [i for i in v["items"] if (i.get("login") or {}).get("username") == USER]
    expect(len(item) == 1 and folders.get(item[0].get("folderId")) == "Agents", "item not in the Agents folder")
    return "folder %s" % got.get("folder")


@job("c1.vault_update", "Change a saved login's password (no twin)", "browser_vault_save", "bw-mock.py",
     "{updated:true, created:false}; still one item for site+user", needs=["browser_vault_save"], watch_user=False)
def _(ctx):
    ensure_vault(ctx)
    global PW
    PW = PW + "-v2"
    got = json.loads(ctx.session().call("browser_vault_save", {"url": ctx.F + "/c1/login.html", "username": USER, "password": PW}).text)
    expect(got.get("updated") and not got.get("created"), "not an update: %s" % got)
    n = [i for i in vault_file(ctx)["items"] if (i.get("login") or {}).get("username") == USER]
    expect(len(n) == 1, "%d items for the same login" % len(n))


@job("c1.vault_note", "Save backup codes as a secure note", "browser_vault_note", "bw-mock.py",
     "{ok}; note text not echoed", seed="bitwarden-add-item-blocked", needs=["browser_vault_note"], watch_user=False)
def _(ctx):
    ensure_vault(ctx, saved=False)
    res = ctx.session().call("browser_vault_note", {"name": "HC backup codes", "text": "1111-2222\n3333-4444"})
    expect("1111-2222" not in res.text, "note text echoed")
    expect(json.loads(res.text).get("ok"), res.text[:200])


@job("c1.vault_save_cli", "Save a login from the shell (stdin JSON)", "copper bitwarden save -", "bw-mock.py",
     "exit 0, {ok}; nothing secret printed", watch_user=False)
def _(ctx):
    ensure_vault(ctx, saved=False)
    code, out, err = ctx.world.cli(["bitwarden", "save", "-"], stdin=json.dumps(
        {"url": ctx.F + "/c1/cli", "username": "cli@example.invalid", "password": "hc-cli-pw-1"}))
    expect("hc-cli-pw-1" not in out + err, "password printed")
    expect(code == 0 and '"ok"' in out, "exit %d: %s" % (code, (err or out)[:200]))


@job("c1.vault_error_redacts", "A failed vault write says why, without the secret", "browser_vault_save", "bw-mock.py (locked)",
     "isError; message says locked/unlock; value not in it", needs=["browser_vault_save"], watch_user=False)
def _(ctx):
    ensure_vault(ctx, saved=False)
    ctx.world.cli(["bitwarden", "lock"])
    ctx.state["vault"] = False
    res = ctx.session().call("browser_vault_save", {"url": ctx.F + "/x", "username": "u@example.invalid",
                                                    "password": "hc-redact-SECRET-77"}, ok=False)
    unlock(ctx)
    expect(res.error, "a locked vault saved anyway: %s" % res.text[:160])
    expect("hc-redact-SECRET-77" not in res.text, "the error contains the password")
    expect(re.search(r"lock|unlock", res.text, re.I), "error doesn't say the vault is locked: %s" % res.text[:160])
    return res.text[:120]


@job("c1.signin_password", "Sign in with a saved login (secret stays in Copper)", "browser_sign_in", "c1/login.html",
     "page got user+password; answer has no password", seed="copper-do-auth-and-2fa", needs=["browser_sign_in"])
def _(ctx):
    ensure_vault(ctx)
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/login.html")
    res = s.call("browser_sign_in", {"tab": tab, "account": USER})
    expect(PW not in res.text, "password in the answer")
    s.wait_r(tab, "signedin", USER)
    sub = s.ev(tab, "() => JSON.stringify(window.__submitted)")
    expect(sub.get("pw") == PW, "the page got a different password")
    return res.text[:100]


@job("c1.signin_otp", "Fill a two-step code from the saved TOTP seed", "browser_sign_in what=otp", "c1/otp.html + /api/totp-check",
     "server accepts the code", seed="copper-do-auth-and-2fa", needs=["browser_sign_in"])
def _(ctx):
    ensure_vault(ctx)
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/otp.html")
    s.call("browser_sign_in", {"tab": tab, "account": USER, "what": "otp"})
    s.wait_r(tab, "otp", lambda v: v in ("ok", "bad"))
    expect(s.r(tab, "otp") == "ok", "server refused the code")


@job("c1.signin_denied", "Unshared login: refused with where to share it", "browser_sign_in", "c1/login.html + unshared bw item",
     "isError naming Settings › Passwords › Agent access; nothing filled", needs=["browser_sign_in"])
def _(ctx):
    ensure_vault(ctx)
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/login.html")
    res = s.call("browser_sign_in", {"tab": tab, "account": "hidden@example.invalid"}, ok=False)
    expect(res.error, "an unshared login was used: %s" % res.text[:160])
    expect("not-shared-pw-1" not in res.text, "leaked")
    expect(s.ev(tab, "() => JSON.stringify(document.getElementById('pass').value.length)") == 0, "password field was filled")
    expect(re.search(r"Agent access", res.text), "error doesn't say where to share it: %s" % res.text[:160])
    return res.text[:120]


@job("c1.signin_iframe_same", "Sign in where the form is in a same-origin iframe", "browser_sign_in", "c1/frame-same.html",
     "frame posts signed-in", seed="copper-blob-download-hang (Apple idmsa iframe)", needs=["browser_sign_in"])
def _(ctx):
    ensure_vault(ctx)
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/frame-same.html")
    s.call("browser_sign_in", {"tab": tab, "account": USER})
    s.wait_r(tab, "framesignedin", USER)


@job("c1.signin_iframe_cross", "Sign in where the form is in a cross-origin iframe", "browser_sign_in", "c1/frame-cross.html",
     "frame posts signed-in", seed="online-ordering-gotchas (PayPal/Amazon iframes)", needs=["browser_sign_in"])
def _(ctx):
    ensure_vault(ctx)
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/frame-cross.html?o=" + ctx.F2)
    s.call("browser_sign_in", {"tab": tab, "account": USER})
    s.wait_r(tab, "framesignedin", USER)


@job("c1.click_in_iframe", "Snapshot + click a button inside a cross-origin iframe", "browser_snapshot → browser_click",
     "c1/frame-button.html", "snapshot has a ref for 'Pay now'; click lands", seed="online-ordering-gotchas (PayPal button in iframe)",
     needs=["browser_snapshot", "browser_click"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/frame-button.html?o=" + ctx.F2)
    time.sleep(0.5)
    ref = s.ref(tab, "Pay now")
    s.call("browser_click", {"tab": tab, "ref": ref})
    s.wait_r(tab, "paid", True)


@job("c1.oauth_popup", "OAuth popup: find it, authorize, back to the opener", "browser_tabs list/select → browser_click",
     "c1/oauth.html → c1/consent.html (2nd origin)", "popup listed with an id; opener gets the token", seed="copper-do-auth-and-2fa",
     needs=["browser_tabs", "browser_click"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/oauth.html?o=" + ctx.F2)
    s.call("browser_click", {"tab": tab, "selector": "#go"})
    pop = None
    for _ in range(20):
        lst = s.call("browser_tabs", {"action": "list"}).text
        m = re.search(r"\[HC Identity[^\]]*\].*?\{tab ([0-9a-zA-Z]+)\}", lst)
        if m:
            pop = m.group(1)
            break
        time.sleep(0.25)
    expect(pop, "the popup never showed up in browser_tabs list")
    s.tabs.append(pop)
    s.call("browser_click", {"tab": pop, "selector": "#ok"})
    s.wait_r(tab, "authorized", "hc-token-ok")


@job("c1.digits_2fa", "Type a code into six one-digit boxes", "browser_type slowly", "c1/digits.html",
     "page reads 123456", seed="copper-do-auth-and-2fa (GitHub device code boxes)", needs=["browser_type"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/digits.html")
    s.call("browser_type", {"tab": tab, "selector": ".d", "text": "123456", "slowly": True})
    s.wait_r(tab, "code", "123456", timeout=4)


@job("c1.passkey", "Create then use a passkey (Touch ID answered by bench)", "browser_click → Copper WebAuthn bridge",
     "c1/passkey.html on localhost", "create ok, get ok", needs=["browser_click"])
def _(ctx):
    try:
        ctx.world.bench(["passkeys", "answer", "yes"])
    except Missing:
        raise Skip("needs bench to answer the Touch ID sheet")
    s = ctx.session()
    tab = s.open(ctx.LH + "/c1/passkey.html")
    try:
        s.call("browser_click", {"tab": tab, "selector": "#create"})
        s.wait_r(tab, "create", lambda v: v != "running", timeout=12)
        expect(s.r(tab, "create") == "ok", "create: %s" % s.r(tab, "create"))
        s.call("browser_click", {"tab": tab, "selector": "#use"})
        s.wait_r(tab, "get", lambda v: v != "running", timeout=12)
        expect(s.r(tab, "get") == "ok", "get: %s" % s.r(tab, "get"))
    finally:
        cid = s.r(tab, "credid") if tab else None
        if cid:
            ctx.world.bench(["passkeys", "forget", "--id", cid])


@job("c1.autofill_card", "Fill a saved card into checkout (values never returned)", "browser_autofill kind=card",
     "c1/card.html + bw-mock card", "number passes Luhn, name/exp/csc filled; number not in answer",
     seed="online-ordering-gotchas (CVV skipped on some sites)", needs=["browser_autofill"])
def _(ctx):
    ensure_vault(ctx, saved=False)
    s = ctx.session()
    tab = s.open(ctx.F + "/c1/card.html")
    res = s.call("browser_autofill", {"tab": tab, "kind": "card", "name": "HC Test Visa"})
    expect("4242424242424242" not in res.text, "card number in the answer")
    card = s.wait_r(tab, "card", lambda c: c.get("num"), timeout=4)
    missed = [k for k, v in card.items() if not v]
    expect(not missed, "not filled: %s" % ", ".join(missed))


# ================================================================ C2 forms + inputs

def forms(ctx):
    s = ctx.session()
    return s, s.open(ctx.F + "/c2/forms.html")


@job("c2.type_controlled", "Type into a React-style controlled input", "browser_type", "c2/forms.html #controlled",
     "the input event delivered the value", needs=["browser_type"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_type", {"tab": tab, "selector": "#controlled", "text": "Ada Lovelace"})
    s.wait_r(tab, "controlled", "Ada Lovelace", timeout=3)


@job("c2.type_slowly", "Type with real key events", "browser_type slowly", "c2/forms.html #keys",
     "≥5 keydowns, value 'hello'", needs=["browser_type"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_type", {"tab": tab, "selector": "#keys", "text": "hello", "slowly": True})
    s.wait_r(tab, "keysvalue", "hello", timeout=3)
    expect((s.r(tab, "keydowns") or 0) >= 5, "only %s keydown events" % s.r(tab, "keydowns"))


@job("c2.submit_enter", "Type and press Enter to submit", "browser_type submit", "c2/forms.html #q",
     "form submit event with the text", needs=["browser_type"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_type", {"tab": tab, "selector": "#q", "text": "needle", "submit": True})
    s.wait_r(tab, "submitted", "needle", timeout=3)


@job("c2.select_native", "Pick an option in a native <select> by label", "browser_select_option", "c2/forms.html #country",
     "change event, value nl", seed="reimb (copper can't pick <select> options from the CLI)", needs=["browser_select_option"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_select_option", {"tab": tab, "selector": "#country", "values": ["Netherlands"]})
    s.wait_r(tab, "country", "nl", timeout=3)


@job("c2.select_multiple", "Pick two options in a multi-select", "browser_select_option", "c2/forms.html #toppings",
     "olive,egg selected", needs=["browser_select_option"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_select_option", {"tab": tab, "selector": "#toppings", "values": ["Olive", "Egg"]})
    s.wait_r(tab, "toppings", "olive,egg", timeout=3)


@job("c2.checkbox_radio", "Tick a checkbox and a radio by ref", "browser_fill_form", "c2/forms.html",
     "agree=true, plan=pro", needs=["browser_fill_form", "browser_snapshot"])
def _(ctx):
    s, tab = forms(ctx)
    agree, pro = s.ref(tab, 'checkbox "I agree'), s.ref(tab, 'radio "Pro"')
    s.call("browser_fill_form", {"tab": tab, "fields": [{"name": "agree", "ref": agree, "type": "checkbox", "value": "true"},
                                                        {"name": "pro", "ref": pro, "type": "radio", "value": "true"}]})
    s.wait_r(tab, "agree", True, timeout=3)
    s.wait_r(tab, "plan", "pro", timeout=3)


@job("c2.date_input", "Set a native <input type=date>", "browser_type", "c2/forms.html #date",
     "value 2026-12-25 with a change event", needs=["browser_type"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_type", {"tab": tab, "selector": "#date", "text": "2026-12-25"})
    s.wait_r(tab, "date", "2026-12-25", timeout=3)


@job("c2.date_picker_widget", "Open a JS calendar and click a day", "browser_click + browser_snapshot", "c2/forms.html #dp",
     "picker = 2026-12-15", needs=["browser_click", "browser_snapshot"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_click", {"tab": tab, "selector": "#dp"})
    s.call("browser_click", {"tab": tab, "ref": s.ref(tab, '"December 15, 2026"')})
    s.wait_r(tab, "picker", "2026-12-15", timeout=3)


@job("c2.slider", "Set a range slider", "browser_fill_form slider", "c2/forms.html #vol", "vol = 70",
     needs=["browser_fill_form", "browser_snapshot"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_fill_form", {"tab": tab, "fields": [{"name": "Volume", "ref": s.ref(tab, 'slider "Volume"'), "type": "slider", "value": "70"}]})
    s.wait_r(tab, "vol", "70", timeout=3)


@job("c2.combobox", "Autocomplete: type, ArrowDown, Enter", "browser_type + browser_press_key", "c2/forms.html #city",
     "city = Amsterdam", needs=["browser_type", "browser_press_key"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_type", {"tab": tab, "selector": "#city", "text": "Am", "slowly": True})
    s.call("browser_press_key", {"tab": tab, "key": "ArrowDown"})
    s.call("browser_press_key", {"tab": tab, "key": "Enter"})
    s.wait_r(tab, "city", "Amsterdam", timeout=3)


@job("c2.contenteditable", "Type into a contenteditable box", "browser_type", "c2/forms.html #ce",
     "input event, text present", needs=["browser_type"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_type", {"tab": tab, "selector": "#ce", "text": "hello notes"})
    s.wait_r(tab, "ce", "hello notes", timeout=3)


@job("c2.rich_text_bold", "Rich text: type, ⌘A, ⌘B", "browser_type + browser_press_key Meta", "c2/forms.html #rte",
     "editor HTML has <b>", needs=["browser_type", "browser_press_key"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_type", {"tab": tab, "selector": "#rte", "text": "make me bold", "slowly": True})
    s.call("browser_press_key", {"tab": tab, "key": "a", "modifiers": ["Meta"]})
    s.call("browser_press_key", {"tab": tab, "key": "b", "modifiers": ["Meta"]})
    s.wait_r(tab, "rte", lambda h: "<b>" in h or "font-weight" in h, timeout=3)


@job("c2.shadow_click", "Click a button inside an open shadow root", "browser_snapshot → browser_click", "c2/forms.html #shadowhost",
     "snapshot ref for 'Apply promo'; click lands", needs=["browser_snapshot", "browser_click"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_click", {"tab": tab, "ref": s.ref(tab, 'button "Apply promo"')})
    s.wait_r(tab, "shadowclick", timeout=3)


@job("c2.shadow_type", "Type into a field inside a shadow root", "browser_snapshot → browser_type", "c2/forms.html #shadowhost",
     "shadowtyped = SAVE10", needs=["browser_snapshot", "browser_type"])
def _(ctx):
    s, tab = forms(ctx)
    s.call("browser_type", {"tab": tab, "ref": s.ref(tab, 'textbox "Promo code"'), "text": "SAVE10"})
    s.wait_r(tab, "shadowtyped", "SAVE10", timeout=3)


@job("c2.file_upload", "Upload a file through <input type=file>", "browser_file_upload", "c2/forms.html #file",
     "page reads the file's name + text", seed="copper-signin-keychain-hang (upload via hooked input + base64 eval chunks)",
     needs=["browser_file_upload"])
def _(ctx):
    s, tab = forms(ctx)
    path = os.path.join(tempfile.mkdtemp(), "hc-upload.txt")
    open(path, "w").write("hello upload")
    s.call("browser_click", {"tab": tab, "selector": "#file"}, ok=False)
    s.call("browser_file_upload", {"tab": tab, "paths": [path]})
    got = s.wait_r(tab, "file", timeout=4)
    expect(got.get("name") == "hc-upload.txt" and got.get("text") == "hello upload", "page got %s" % got)


# ================================================================ C3 files out

def wait_file(ctx, name, timeout=10):
    t0 = time.time()
    while time.time() - t0 < timeout:
        hits = glob.glob(os.path.join(ctx.world.folder, "Downloads", name.replace(".csv", "*.csv")))
        hits = [h for h in hits if not h.endswith((".download", ".part"))]
        if hits:
            return hits[0]
        time.sleep(0.25)
    raise Fail("%s never landed in the world's Downloads folder" % name)


def download(ctx, selector, name):
    s = ctx.session()
    tab = s.open(ctx.F + "/c3/files.html")
    s.call("browser_click", {"tab": tab, "selector": selector}, timeout=15)
    path = wait_file(ctx, name)
    s.call("browser_tabs", {"action": "list"}, timeout=8)  # Copper still answering
    return os.path.basename(path)


@job("c3.download_link", "Download an <a download> link", "browser_click", "c3/files.html #dl",
     "file in <world>/Downloads; Copper still answers", needs=["browser_click"])
def _(ctx):
    return download(ctx, "#dl", "hc-report.csv")


@job("c3.download_attachment", "Download a Content-Disposition attachment", "browser_click", "c3/files.html #att → /files/attachment",
     "file in Downloads", needs=["browser_click"])
def _(ctx):
    return download(ctx, "#att", "hc-attachment.csv")


@job("c3.download_blob", "Download a generated blob: URL", "browser_click", "c3/files.html #blob",
     "file in Downloads; Copper does not hang", seed="copper-blob-download-hang", needs=["browser_click"])
def _(ctx):
    return download(ctx, "#blob", "hc-blob.csv")


@job("c3.downloads_tool", "Ask where a download went (list downloads)", "browser_downloads (proposed)", "c3/files.html",
     "a tool returns the finished file's path", seed="copper-blob-download-hang (no way to get a file out)",
     needs=["browser_downloads"])
def _(ctx):
    s = ctx.session()
    s.open(ctx.F + "/c3/files.html")
    s.call("browser_click", {"selector": "#dl"})
    res = s.call("browser_downloads", {})
    expect("hc-report" in res.text, res.text[:200])


@job("c3.pdf_save", "Save the page as PDF", "browser_pdf_save (Playwright name)", "c3/long.html",
     "a PDF file with ≥2 pages", needs=["browser_pdf_save"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c3/long.html")
    path = os.path.join(tempfile.mkdtemp(), "hc.pdf")
    s.call("browser_pdf_save", {"tab": tab, "filename": path})
    expect(open(path, "rb").read(5) == b"%PDF-", "not a PDF")


def shot(s, tab, **kw):
    res = s.call("browser_take_screenshot", dict(kw, tab=tab, type="png"), timeout=30)
    expect(res.images, "no image in the answer")
    return png_info(res.images[0])


@job("c3.screenshot_viewport", "Screenshot the viewport at 1× CSS px", "browser_take_screenshot", "c3/long.html",
     "PNG = innerWidth × innerHeight; top band blue", needs=["browser_take_screenshot"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c3/long.html")
    vw = s.ev(tab, "() => JSON.stringify([innerWidth, innerHeight])")
    w, h, px = shot(s, tab)
    expect(abs(w - vw[0]) <= 2 and abs(h - vw[1]) <= 2, "image %dx%d, viewport %dx%d" % (w, h, vw[0], vw[1]))
    expect(px is None or px(10, 10)[2] > 150, "top-left isn't the blue band: %s" % (px(10, 10),))
    return "%dx%d" % (w, h)


@job("c3.screenshot_fullpage", "Full-page screenshot that reveals scroll-lazy content", "browser_take_screenshot fullPage",
     "c3/long.html (IntersectionObserver turns #lazy green)", "height ≈ scrollHeight; #lazy green in the picture",
     seed="copper-eval-slack-showcase (shot --full doesn't scroll)", needs=["browser_take_screenshot"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c3/long.html")
    g = s.ev(tab, "() => JSON.stringify([document.documentElement.scrollHeight, document.getElementById('lazy').offsetTop])")
    w, h, px = shot(s, tab, fullPage=True)
    expect(h >= g[0] * 0.95, "image %d px tall, page %d" % (h, g[0]))
    if px:
        r, gr, b = px(w // 2, g[1] + 250)
        expect(gr > r, "lazy section is red in the picture (never scrolled into view)")
    return "%dx%d" % (w, h)


@job("c3.screenshot_element", "Screenshot one element by ref", "browser_take_screenshot ref", "c2/forms.html Send",
     "image ≈ the button's box", needs=["browser_take_screenshot", "browser_snapshot"])
def _(ctx):
    s, tab = forms(ctx)
    ref = s.ref(tab, '"Send"')
    box = s.ev(tab, "() => { const r = document.getElementById('submit').getBoundingClientRect(); return JSON.stringify([r.width, r.height]) }")
    w, h, _ = shot(s, tab, ref=ref)
    expect(abs(w - box[0]) <= 6 and abs(h - box[1]) <= 6, "image %dx%d, element %dx%d" % (w, h, box[0], box[1]))


@job("c3.shot_cli_full", "Full-page screenshot to a file from the CLI", "copper --tab ID shot --full PATH", "c3/long.html",
     "PNG on disk, height ≈ scrollHeight", seed="copper-eval-slack-showcase", needs=["browser_take_screenshot"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c3/long.html")
    path = os.path.join(tempfile.mkdtemp(), "hc-full.png")
    code, out, err = ctx.world.cli(["--tab", tab, "shot", "--full", path])
    expect(code == 0 and os.path.exists(path), "exit %d: %s" % (code, (err or out)[:200]))
    w, h, _ = png_info(open(path, "rb").read())
    sh = s.ev(tab, "() => JSON.stringify(document.documentElement.scrollHeight)")
    expect(h >= sh * 0.95, "file %d px tall, page %d" % (h, sh))


# ================================================================ C4 page + JS

def jspage(ctx):
    s = ctx.session()
    return s, s.open(ctx.F + "/c4/js.html")


@job("c4.eval_sync", "Evaluate a sync function", "browser_evaluate", "c4/js.html", "returns the title", needs=["browser_evaluate"])
def _(ctx):
    s, tab = jspage(ctx)
    t = s.call("browser_evaluate", {"tab": tab, "function": "() => document.title"}).text
    expect(t == "HC page and JS", repr(t[:80]))


@job("c4.eval_async", "Evaluate an async function (await inside)", "browser_evaluate", "c4/js.html", "returns 42",
     seed="copper-blob-download-hang, copper-eval-slack-showcase (async fails)", needs=["browser_evaluate"])
def _(ctx):
    s, tab = jspage(ctx)
    t = s.call("browser_evaluate", {"tab": tab, "function": "async () => { await new Promise(r => setTimeout(r, 50)); return 6 * 7 }"}).text
    expect(t.strip() == "42", "got %r" % t[:120])


@job("c4.eval_fetch", "Evaluate a Promise (fetch → json)", "browser_evaluate", "c4/js.html + /api/json", "returns 42",
     seed="copper-eval-slack-showcase (use sync XHR instead)", needs=["browser_evaluate"])
def _(ctx):
    s, tab = jspage(ctx)
    t = s.call("browser_evaluate", {"tab": tab, "function": "() => fetch('/api/json').then(r => r.json()).then(j => j.answer)"}).text
    expect(t.strip() == "42", "got %r" % t[:120])


@job("c4.eval_cli_expr", "CLI eval of a plain expression", "copper --tab ID eval 'document.title'", "c4/js.html",
     "prints the title", seed="copper-eval-slack-showcase, reve (copper eval fails)", needs=["browser_evaluate"])
def _(ctx):
    s, tab = jspage(ctx)
    code, out, err = ctx.world.cli(["--tab", tab, "eval", "document.title"])
    expect(code == 0 and "HC page and JS" in out, "exit %d: %s" % (code, (err or out).strip()[:200]))


@job("c4.eval_cli_fn", "CLI eval of an arrow function", "copper --tab ID eval '() => …'", "c4/js.html", "prints the title",
     needs=["browser_evaluate"])
def _(ctx):
    s, tab = jspage(ctx)
    code, out, err = ctx.world.cli(["--tab", tab, "eval", "() => document.title"])
    expect(code == 0 and "HC page and JS" in out, "exit %d: %s" % (code, (err or out).strip()[:200]))


@job("c4.eval_element", "Evaluate with an element ref", "browser_evaluate ref", "c4/js.html", "(el) => el.id gives 'alert'",
     needs=["browser_evaluate", "browser_snapshot"])
def _(ctx):
    s, tab = jspage(ctx)
    t = s.call("browser_evaluate", {"tab": tab, "ref": s.ref(tab, 'button "Submit (alerts)"'), "function": "(el) => el.id"}).text
    expect(t == "alert", repr(t[:80]))


@job("c4.eval_error_message", "A thrown error comes back with its message", "browser_evaluate", "c4/js.html",
     "isError text contains the message", needs=["browser_evaluate"])
def _(ctx):
    s, tab = jspage(ctx)
    res = s.call("browser_evaluate", {"tab": tab, "function": "() => { throw new Error('hc-boom-17') }"}, ok=False)
    expect(res.error and "hc-boom-17" in res.text, "got %r" % res.text[:160])


@job("c4.alert_no_hang", "A page alert() doesn't wedge the tab", "browser_click → browser_evaluate", "c4/js.html #alert",
     "the next call answers in <8 s", seed="copper-js-alert-hangs-tab", needs=["browser_click"])
def _(ctx):
    s, tab = jspage(ctx)
    s.call("browser_click", {"tab": tab, "selector": "#alert"}, timeout=10)
    s.wait_r(tab, "afteralert", True, timeout=8)


@job("c4.alert_text_visible", "The agent learns what an alert said", "browser_click / browser_console_messages", "c4/js.html #alert",
     "'Please select an item type' appears in a tool answer", seed="copper-js-alert-hangs-tab (chargerback form)", needs=["browser_click"])
def _(ctx):
    s, tab = jspage(ctx)
    said = s.call("browser_click", {"tab": tab, "selector": "#alert"}, timeout=10).text
    said += s.call("browser_console_messages", {"tab": tab}, timeout=10, ok=False).text
    said += s.call("browser_snapshot", {"tab": tab, "interactive": True}, timeout=10, ok=False).text
    expect("Please select an item type" in said, "no tool answer carries the alert's text")


@job("c4.dialog_accept", "Accept a confirm() dialog", "browser_handle_dialog (Playwright name)", "c4/js.html #confirm",
     "confirm returned true", seed="copper-js-alert-hangs-tab (override window.confirm by hand)", needs=["browser_handle_dialog"])
def _(ctx):
    s, tab = jspage(ctx)
    s.call("browser_click", {"tab": tab, "selector": "#confirm"}, ok=False)
    s.call("browser_handle_dialog", {"tab": tab, "accept": True})
    s.wait_r(tab, "confirm", True)


@job("c4.dialog_prompt", "Answer a prompt() dialog", "browser_handle_dialog promptText", "c4/js.html #prompt",
     "prompt returned the text", needs=["browser_handle_dialog"])
def _(ctx):
    s, tab = jspage(ctx)
    s.call("browser_click", {"tab": tab, "selector": "#prompt"}, ok=False)
    s.call("browser_handle_dialog", {"tab": tab, "accept": True, "promptText": "copy 2"})
    s.wait_r(tab, "prompt", "copy 2")


@job("c4.console_messages", "Read console warn/error after an action", "browser_console_messages", "c4/js.html #log",
     "both messages listed", needs=["browser_console_messages"])
def _(ctx):
    s, tab = jspage(ctx)
    s.call("browser_console_messages", {"tab": tab})  # whatever starts capturing
    s.call("browser_click", {"tab": tab, "selector": "#log"})
    t = s.call("browser_console_messages", {"tab": tab}).text
    expect("hc-warn clicked" in t and "hc-error clicked" in t, "got %r" % t[:200])


@job("c4.console_load", "Read console logs from page load (before any tool call)", "browser_console_messages", "c4/js.html",
     "'hc-early-log' (logged while parsing) listed", needs=["browser_console_messages"])
def _(ctx):
    s, tab = jspage(ctx)
    t = s.call("browser_console_messages", {"tab": tab}).text
    expect("hc-early-log" in t, "load-time logs lost: %r" % t[:200])


@job("c4.network_requests", "List the page's network requests", "browser_network_requests (Playwright name)", "c4/js.html #xhr",
     "/api/json?from=page listed with status 200", needs=["browser_network_requests"])
def _(ctx):
    s, tab = jspage(ctx)
    s.call("browser_click", {"tab": tab, "selector": "#xhr"})
    s.wait_r(tab, "fetched", 42)
    t = s.call("browser_network_requests", {"tab": tab}).text
    expect("/api/json?from=page" in t, t[:200])


@job("c4.wait_for_text", "Wait for text that appears later", "browser_wait_for text", "c4/js.html #later",
     "returns once 'Report ready' is there, <5 s", needs=["browser_wait_for"])
def _(ctx):
    s, tab = jspage(ctx)
    s.call("browser_click", {"tab": tab, "selector": "#later"})
    t0 = time.time()
    s.call("browser_wait_for", {"tab": tab, "text": "Report ready"})
    expect(time.time() - t0 < 5, "took %.1f s" % (time.time() - t0))
    expect("17 rows" in s.call("browser_get_text", {"tab": tab}).text, "text not there after the wait")


@job("c4.get_text", "Read the page's text", "browser_get_text", "c4/js.html", "has the paragraph", needs=["browser_get_text"])
def _(ctx):
    s, tab = jspage(ctx)
    expect("quick brown fox" in s.call("browser_get_text", {"tab": tab}).text, "paragraph missing")


@job("c4.find_text", "Find text → a ref to act on", "browser_find", "c4/js.html", "a ref for 'Build report'",
     needs=["browser_find"])
def _(ctx):
    s, tab = jspage(ctx)
    t = s.call("browser_find", {"tab": tab, "text": "Build report"}).text
    expect(re.search(r"ref=e\d+|\be\d+\b", t), t[:160])


@job("c4.back_forward", "Back and forward", "browser_navigate_back / _forward", "c4/js.html ↔ c4/next.html",
     "URL follows", needs=["browser_navigate_back", "browser_navigate_forward"])
def _(ctx):
    s, tab = jspage(ctx)
    s.call("browser_click", {"tab": tab, "selector": "#next"})
    expect("next.html" in s.call("browser_snapshot", {"tab": tab, "interactive": True}).text, "click didn't navigate")
    expect("js.html" in s.call("browser_navigate_back", {"tab": tab}).text, "back didn't land on js.html")
    expect("next.html" in s.call("browser_navigate_forward", {"tab": tab}).text, "forward didn't land on next.html")


# ================================================================ C5 tabs + browser state

@job("c5.tab_new_background", "Open a tab of my own without moving the user", "browser_tabs new", "c7/note.html",
     "answer says background + id; user's tab still on screen", seed="copper-tabs-by-id-only", needs=["browser_tabs"])
def _(ctx):
    s = ctx.session()
    res = s.call("browser_tabs", {"action": "new", "url": ctx.F + "/c7/note.html"})
    m = re.search(r"\{tab ([0-9a-zA-Z]+)\}", res.text)
    expect(m, "no tab id")
    s.tabs.append(m.group(1))
    expect("background" in res.text, res.text[:120])


@job("c5.tab_select_close_by_id", "Select and close tabs by id", "browser_tabs select/close tab=ID", "c7/note.html ×2",
     "calls land on the selected tab; closed one is gone", seed="copper-tabs-by-id-only", needs=["browser_tabs"])
def _(ctx):
    s = ctx.session()
    a, b = s.open(ctx.F + "/c7/note.html?a"), s.open(ctx.F + "/c7/note.html?b")
    s.call("browser_tabs", {"action": "select", "tab": a})
    s.call("browser_type", {"selector": "#t", "text": "to-a"})
    expect(s.r(a, "typed") == "to-a" and s.r(b, "typed") is None, "typing didn't land on the selected tab")
    s.call("browser_tabs", {"action": "close", "tab": b})
    lst = s.call("browser_tabs", {"action": "list"}).text
    expect(b not in lst and a in lst, "list after close is wrong")


@job("c5.groups", "Put my tab in a folder/group", "browser_groups assign/list/remove", "c7/note.html",
     "list shows the group with the tab", needs=["browser_groups"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c7/note.html")
    s.call("browser_groups", {"tab": tab, "action": "assign", "group": "HC Coverage"})
    t = s.call("browser_groups", {"action": "list"}).text
    s.call("browser_groups", {"tab": tab, "action": "remove"})
    expect("HC Coverage" in t and "HC note" in t, t[:200])


@job("c5.spaces", "List spaces / open a tab in a named space", "browser_spaces (proposed)", "—",
     "spaces listed; tab lands in the space", needs=["browser_spaces"])
def _(ctx):
    ctx.session().call("browser_spaces", {"action": "list"})


@job("c5.bookmarks", "Add and search bookmarks", "browser_bookmarks (proposed)", "c7/note.html",
     "bookmark added and found", needs=["browser_bookmarks"])
def _(ctx):
    ctx.session().call("browser_bookmarks", {"action": "list"})


@job("c5.history", "Search browsing history", "browser_history (proposed; only cloud_history_delete exists)", "c4/js.html visited",
     "the visit is found", needs=["browser_history"])
def _(ctx):
    ctx.session().call("browser_history", {"query": "HC page"})


@job("c5.cookies_httponly", "Read an HttpOnly session cookie", "browser_cookies (proposed)", "c5/state.html (/api/set-cookie)",
     "hc_session listed (document.cookie can't see it)", needs=["browser_cookies"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c5/state.html")
    s.wait_r(tab, "cookies", "set")
    expect("hc_session" in s.call("browser_cookies", {"tab": tab}).text, "not listed")


@job("c5.storage_local", "Read localStorage / sessionStorage", "browser_evaluate", "c5/state.html", "both values read",
     needs=["browser_evaluate"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c5/state.html")
    got = s.ev(tab, "() => JSON.stringify([localStorage.getItem('hc-local'), sessionStorage.getItem('hc-session')])")
    expect(got == ["kept-value", "tab-value"], got)


@job("c5.permission_geo", "Grant a site location permission", "browser_permissions (proposed)", "c5/state.html #where",
     "geolocation succeeds after the grant", needs=["browser_permissions"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c5/state.html")
    s.call("browser_permissions", {"tab": tab, "grant": ["geolocation"]})
    s.call("browser_click", {"tab": tab, "selector": "#where"})
    s.wait_r(tab, "geo", "granted")


@job("c5.resize", "Resize the window (responsive check)", "browser_resize", "c7/note.html", "innerWidth follows",
     needs=["browser_resize"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c7/note.html")
    before = s.ev(tab, "() => JSON.stringify(innerWidth)")
    s.call("browser_resize", {"width": 1000, "height": 760})
    for _ in range(10):  # the page learns the new size a beat later
        after = s.ev(tab, "() => JSON.stringify(innerWidth)")
        if after < before:
            break
        time.sleep(0.2)
    s.call("browser_resize", {"width": 1440, "height": 900})
    expect(after < before, "innerWidth %s → %s" % (before, after))


# ================================================================ C6 hard UI

@job("c6.hover_menu", "Open a hover menu and click its item", "browser_hover → browser_click", "c6/hover.html",
     "menu = signout", needs=["browser_hover", "browser_click"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/hover.html")
    s.call("browser_hover", {"tab": tab, "selector": "#trigger"})
    s.call("browser_click", {"tab": tab, "selector": "#signout"})
    s.wait_r(tab, "menu", "signout", timeout=3)


@job("c6.drag_html5", "HTML5 drag and drop (card → column)", "browser_drag", "c6/drag.html #card → #to",
     "drop event fired", needs=["browser_drag", "browser_find"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/drag.html")
    a, b = refs_of(s, tab, "Card A"), refs_of(s, tab, "Done")
    s.call("browser_drag", {"tab": tab, "startRef": a, "endRef": b, "startElement": "Card A", "endElement": "Done"})
    s.wait_r(tab, "dropped", "to", timeout=3)


def refs_of(s, tab, text):
    t = s.call("browser_find", {"tab": tab, "text": text}).text
    m = re.search(r"ref=(e\d+)", t) or re.search(r"\b(e\d+)\b", t)
    expect(m, "browser_find gave no ref for %r: %s" % (text, t[:120]))
    return m.group(1)


@job("c6.drag_pointer", "Reorder a mouse-event sortable list", "browser_drag", "c6/drag.html #list",
     "order changes ('One' no longer first)", needs=["browser_drag", "browser_find"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/drag.html")
    s.call("browser_drag", {"tab": tab, "startRef": refs_of(s, tab, "One"), "endRef": refs_of(s, tab, "Three")})
    s.wait_r(tab, "order", lambda o: not o.startswith("One"), timeout=3)


@job("c6.canvas_xy", "Click a point on a canvas", "browser_mouse_click_xy (Playwright vision tool)", "c6/canvas.html",
     "the red circle at (470,300) is hit", needs=["browser_mouse_click_xy"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/canvas.html")
    off = s.ev(tab, "() => { const r = document.getElementById('c').getBoundingClientRect(); return JSON.stringify([r.left, r.top]) }")
    s.call("browser_mouse_click_xy", {"tab": tab, "x": off[0] + 470, "y": off[1] + 300, "element": "red circle"})
    expect(s.wait_r(tab, "canvasclick").get("hit"), "missed")


@job("c6.virtual_list", "Reach + click row 7321 of a virtualized list", "browser_scroll ref → browser_find → browser_click",
     "c6/virtual.html", "picked = 7321", needs=["browser_scroll", "browser_find", "browser_click"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/virtual.html")
    s.call("browser_scroll", {"tab": tab, "ref": refs_of(s, tab, "Order #0"), "deltaY": 7321 * 30 - 60})
    time.sleep(0.3)
    s.call("browser_click", {"tab": tab, "ref": refs_of(s, tab, "Order #7321")})
    s.wait_r(tab, "picked", 7321, timeout=3)


@job("c6.infinite_scroll", "Scroll an infinite feed to load more", "browser_scroll", "c6/infinite.html", "≥ 40 posts after 6 scrolls",
     needs=["browser_scroll"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/infinite.html")
    for _ in range(6):
        s.call("browser_scroll", {"tab": tab, "deltaY": 1500})
        time.sleep(0.35)
    n = s.r(tab, "posts")
    expect(n >= 40, "%s posts" % n)
    return "%s posts" % n


@job("c6.far_click", "Click a button far below the fold", "browser_click", "c6/far.html #accept", "clicked",
     needs=["browser_click"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/far.html")
    s.call("browser_click", {"tab": tab, "selector": "#accept"})
    s.wait_r(tab, "farclick", True, timeout=3)


@job("c6.occluded_click", "Clicking under a cookie wall says it's covered", "browser_click", "c6/overlay.html #buy",
     "error names the cover (or the click truly lands); never a silent click on the wall", needs=["browser_click"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/overlay.html")
    res = s.call("browser_click", {"tab": tab, "selector": "#buy"}, ok=False)
    r = s.r(tab)
    if r.get("buy"):
        return "click reached the covered button"
    expect(res.error, "said '%s' but clicked the cookie wall" % res.text[:60] if r.get("wallclicked") else "said '%s', nothing happened" % res.text[:60])
    expect(re.search(r"cover|obscur|intercept|overlay|on top", res.text, re.I), "error doesn't name the cover: %s" % res.text[:160])


@job("c6.tab_key_focus", "Tab moves focus to the next field", "browser_press_key Tab", "c6/far.html #tab1 → #tab2",
     "focus = tab2", seed="ROADMAP (Tab in forms)", needs=["browser_press_key", "browser_click"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/far.html")
    s.call("browser_click", {"tab": tab, "selector": "#tab1"})
    s.call("browser_press_key", {"tab": tab, "key": "Tab"})
    s.wait_r(tab, "focus", "tab2", timeout=3)


@job("c6.captcha_handback", "Hand a human check back to the person", "browser_handoff (proposed; Jev says BLOCKED)",
     "c6/captcha.html", "a tool parks the run and asks the person; box not ticked by the agent",
     seed="online-ordering-gotchas (Amazon 'I am human')", needs=["browser_handoff"])
def _(ctx):
    s = ctx.session()
    tab = s.open(ctx.F + "/c6/captcha.html")
    s.call("browser_handoff", {"tab": tab, "reason": "human verification"})


# ================================================================ C7 reliability

@job("c7.tab_id_discipline", "Act on tab A by id while tab B is 'mine'", "tab=ID on every page tool", "c7/note.html ×2",
     "only A changes", seed="copper-tabs-by-id-only", needs=["browser_type"])
def _(ctx):
    s = ctx.session()
    a, b = s.open(ctx.F + "/c7/note.html?a"), s.open(ctx.F + "/c7/note.html?b")
    s.call("browser_type", {"tab": a, "selector": "#t", "text": "for-a"})
    expect(s.r(a, "typed") == "for-a", "A didn't get it")
    expect(s.r(b, "typed") is None, "B (my latest tab) got it")


@job("c7.close_then_call", "After closing my tab, a call without tab= doesn't hit the user's tab",
     "browser_close → browser_navigate", "index.html (user's) + c7/note.html", "user's tab URL unchanged (or a clear refusal)",
     seed="copper-tabs-by-id-only (rebound to Collin's tab)", needs=["browser_close", "browser_navigate"])
def _(ctx):
    s = ctx.session()
    s.open(ctx.F + "/c7/note.html")
    s.call("browser_close", {})
    s.tabs = []
    res = s.call("browser_navigate", {"url": ctx.F + "/c4/next.html"}, ok=False)
    line = ctx.user_tab_line()
    expect("next.html" not in line, "navigated the user's on-screen tab")
    return "refused: " + res.text[:100] if res.error else "landed elsewhere"


@job("c7.concurrent_drivers", "Two agents type at once, each in its own tab", "two MCP sessions, browser_type",
     "c7/note.html ×2", "each tab has only its own text", needs=["browser_type"])
def _(ctx):
    s1, s2 = ctx.session("hc-agent-1"), ctx.session("hc-agent-2")
    t1, t2 = s1.open(ctx.F + "/c7/note.html?1"), s2.open(ctx.F + "/c7/note.html?2")
    errs = []

    def work(s, word):
        try:
            for i in range(5):
                s.call("browser_type", {"selector": "#t", "text": "%s-%d" % (word, i)})
        except Exception as e:
            errs.append(str(e))
    th = [threading.Thread(target=work, args=(s1, "alpha")), threading.Thread(target=work, args=(s2, "beta"))]
    [t.start() for t in th]
    [t.join(60) for t in th]
    expect(not errs, "; ".join(errs)[:200])
    expect(s1.r(t1, "typed") == "alpha-4" and s2.r(t2, "typed") == "beta-4",
           "tab 1 %r, tab 2 %r" % (s1.r(t1, "typed"), s2.r(t2, "typed")))


@job("c7.hung_tab_isolation", "A hung page doesn't block calls on other tabs", "any page tool", "c7/busy.html (60 s loop) + c7/note.html",
     "get_text on the other tab answers in <10 s", seed="reve/amex (99% CPU tab hung every copper call)", needs=["browser_get_text"])
def _(ctx):
    s = ctx.session()
    busy, other = s.open(ctx.F + "/c7/busy.html"), s.open(ctx.F2 + "/c7/note.html")
    s.call("browser_click", {"tab": busy, "selector": "#spin"})
    time.sleep(0.6)
    t0 = time.time()
    s.call("browser_get_text", {"tab": other}, timeout=10)
    s.call("browser_tabs", {"action": "list"}, timeout=10)
    return "other tab answered in %.1f s" % (time.time() - t0)


@job("c7.stale_ref_error", "A stale ref says to take a new snapshot", "browser_click ref", "c2/forms.html → c4/js.html",
     "isError mentioning snapshot", needs=["browser_click", "browser_snapshot"])
def _(ctx):
    s, tab = forms(ctx)
    ref = s.ref(tab, '"Send"')
    s.call("browser_navigate", {"tab": tab, "url": ctx.F + "/c4/js.html"})
    res = s.call("browser_click", {"tab": tab, "ref": ref}, ok=False)
    expect(res.error, "a stale ref clicked something: %s" % res.text[:120])
    expect("snapshot" in res.text.lower(), "error doesn't say what to do: %s" % res.text[:160])


@job("c7.bad_tab_error", "An unknown tab id says how to find one", "tab=ID", "—", "isError pointing at browser_tabs list",
     needs=["browser_get_text"])
def _(ctx):
    res = ctx.session().call("browser_get_text", {"tab": "zz9zz9zz"}, ok=False)
    expect(res.error, "an unknown tab answered: %s" % res.text[:100])
    expect(re.search(r"browser_tabs|copper tabs|Open tabs", res.text), "error doesn't say how to find a tab: %s" % res.text[:160])


@job("c7.health_cli", "Is Copper up? (CLI health)", "copper health --json", "—", "running: true", watch_user=False)
def _(ctx):
    code, out, err = ctx.world.cli(["health", "--json"])
    expect(code == 0 and '"running":true' in out.replace(" ", ""), "exit %d: %s" % (code, (out or err)[:160]))


@job("c7.cli_verbs", "CLI has verbs for the everyday page actions", "copper help", "—",
     "select, hover, scroll, wait, back, upload, dialog, pdf, downloads all present", seed="reimb (no CLI select)", watch_user=False)
def _(ctx):
    code, out, err = ctx.world.cli(["help"])
    text = out + err
    want = ["select", "hover", "scroll", "wait", "back", "upload", "dialog", "pdf", "downloads"]
    lacking = [v for v in want if not re.search(r"copper[^\n]*\b%s\b" % v, text)]
    expect(not lacking, "no CLI verb for: " + ", ".join(lacking) + " (only `copper call TOOL JSON`)")


@job("c7.not_running_cli", "'Copper isn't running' is clear and fast", "copper tabs (world stopped)", "—",
     "exit ≠ 0 in <5 s; message says it isn't running and how to start it", seed="copper-laptop-fd-crash", watch_user=False)
def _(ctx):
    ctx.world.stop()
    t0 = time.time()
    code, out, err = ctx.world.cli(["tabs"], timeout=30)
    dt = time.time() - t0
    msg = (err or out).strip()
    ctx.world.start(fresh=False)
    ctx.setup()
    expect(code != 0, "exit 0 with Copper down")
    expect(dt < 5, "took %.1f s" % dt)
    expect(re.search(r"not running|isn.t running", msg, re.I) and re.search(r"--launch|open ", msg), "message: %s" % msg[:200])
    return msg[:120]
