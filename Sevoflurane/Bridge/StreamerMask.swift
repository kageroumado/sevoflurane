import Foundation

/// The page half of ``StreamerMode``: a script that masks the signed-in
/// account in every Steam window while the mode is on.
///
/// It runs in the served `index.html`, where Steam's whole UI lives and every
/// popup renders from, and as a user script in each store and community web
/// view. It learns the account at runtime — the persona name, the account
/// name and the avatar hash from Steam's own stores, and in a web page from
/// its header — and rewrites text, attributes and avatar images to the chosen
/// name and picture, keeping up with a `MutationObserver` and a short poll for
/// what the stores learn later. Each friend and group-chat member becomes an
/// AI model with a monogram picture; an in-game one plays that model's
/// favorite game. The wallet balance, pending balance included, is removed in
/// whatever currency the client formats it.
nonisolated enum StreamerMask {
    /// The `<script>` element for the served page's `<head>`, or nothing while
    /// the mode is off.
    static func headTag(for settings: StreamerMode.Settings) -> String {
        guard let script = script(for: settings) else { return "" }
        return "<script>\(script)</script>"
    }

    /// The script for these settings, or `nil` while the mode is off.
    static func script(for settings: StreamerMode.Settings) -> String? {
        guard settings.isOn else { return nil }
        let known = settings.knownNames.map(JSLiteral.inlineString).joined(separator: ",")
        return "(()=>{if(window.__sevoMask)return;window.__sevoMask=1;\n"
            + "const ME_NAME=\(JSLiteral.inlineString(settings.displayName)),ME=\(JSLiteral.inlineString(settings.avatarDataURI)),"
            + "KNOWN=[\(known)];\n"
            + body
            + "})();\n"
    }

    /// Everything after the settings. Each friend is named from `ROSTER` in
    /// the order the friends list shows them — in game first, then online,
    /// then offline, then group-chat members who are not friends — and a
    /// roster that runs out starts again with a number after the name.
    private static let body = #"""
    const ROSTER=["Claude","ChatGPT","Gemini","Grok","DeepSeek","Llama","Mistral","Qwen","Copilot","Kimi","Perplexity",
     "Claude Opus","Claude Sonnet","Claude Haiku","GPT-5","o3","Codex","Gemini Flash","Gemma","Meta AI","Le Chat",
     "Codestral","DeepSeek-R1","QwQ","MiniMax","GLM","Phi","Command R","Aya","Jamba","Granite","Nova","OLMo","SmolLM",
     "Yi","Bard","Titan"];
    const art=id=>"https://shared.steamstatic.com/store_item_assets/steam/apps/"+id+"/header.jpg";
    const FAV={"Claude":["Pokémon Red",null],"Gemini":["Pokémon Blue",null],
     "ChatGPT":["GeoGuessr","https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/3478870/d26a05bdaf448c04c8b0e2cd0ba080ef6a0b87a4/capsule_231x87.jpg"],
     "Grok":["Path of Exile 2",art(2694490)],"DeepSeek":["Factorio",art(427520)],"Llama":["Beat Saber",art(620980)],
     "Meta AI":["Beat Saber",art(620980)],"Mistral":["Clair Obscur: Expedition 33",art(1903340)],
     "Le Chat":["Clair Obscur: Expedition 33",art(1903340)],"Qwen":["Black Myth: Wukong",art(2358720)],
     "Copilot":["Microsoft Flight Simulator 2024",art(2537590)],"Kimi":["Baba Is You",art(736260)],
     "Perplexity":["Outer Wilds",art(753640)],"Claude Opus":["The Talos Principle 2",art(835960)],
     "Claude Sonnet":["Slay the Spire",art(646570)],"Claude Haiku":["Balatro",art(2379780)],
     "GPT-5":["Sid Meier’s Civilization® VI",art(289070)],"o3":["The Witness",art(210970)],
     "QwQ":["The Witness",art(210970)],"Codex":["SHENZHEN I/O",art(504210)],"Codestral":["TIS-100",art(370360)],
     "DeepSeek-R1":["Opus Magnum",art(558990)],"Gemini Flash":["Hades",art(1145360)],"Gemma":["Stardew Valley",art(413150)]};
    const FAV_DEFAULT=["Portal 2",art(620)];
    const DEFAULT_AV="fef49e7fa7e1997310d705b2a6158ff8dc1cdfeb";
    const HASH=/[0-9a-f]{40}/;
    
    function hue(s){let h=2166136261;for(let i=0;i<s.length;i++)h=Math.imul(h^s.charCodeAt(i),16777619)>>>0;return h%360}
    function letters(s){const w=s.split(/[ \-_]+/).filter(Boolean);if(!w.length)return"?";const a=Array.from(w[0]);
     if(w.length>1)return(a[0]+Array.from(w[1])[0]).toUpperCase();
     const n=a.slice(1).find(c=>/[\p{Lu}\p{N}]/u.test(c));return(a[0]+(n||"")).toUpperCase()}
    function monogram(s){const t=letters(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
     const svg="<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'><rect width='64' height='64' fill='hsl("+hue(s)+",45%,42%)'/>"
      +"<text x='32' y='32' dy='.35em' text-anchor='middle' fill='#fff' font-size='28' font-weight='600' font-family='-apple-system,Helvetica,Arial,sans-serif'>"+t+"</text></svg>";
     return"data:image/svg+xml,"+encodeURIComponent(svg)}
    const pictures=new Map();
    const pictureOf=s=>{if(!pictures.has(s))pictures.set(s,monogram(s));return pictures.get(s)};
    
    const esc=s=>s.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
    const names=new Map(),hashes=new Map(),seen=new Map(),SELF=new Set(),BAL=new Set();
    const OUT=new Set([ME_NAME,...ROSTER].map(n=>n.toLowerCase()));
    const isOut=n=>OUT.has(n.toLowerCase().replace(/ \d+$/,""));
    let RX=null,EXACT=new Map();
    function learnName(n,label,self){if(!n||!n.trim())return false;const k=n.trim().toLowerCase();
     if(names.has(k)||isOut(k))return false;names.set(k,label);if(self)SELF.add(k);return true}
    for(const n of KNOWN)learnName(n,ME_NAME,true);
    function rebuild(){const keys=[...names.keys()].filter(k=>SELF.has(k)||k.length>=3).sort((a,b)=>b.length-a.length)
      .map(k=>"(?<![\\p{L}\\p{N}_])"+esc(k)+"(?![\\p{L}\\p{N}_])");
     RX=new RegExp(keys.length?keys.join("|"):"(?!)","giu");EXACT=new Map([...names].filter(([k])=>!SELF.has(k)&&k.length<3))}
    
    function learnSelf(){let changed=false;const app=window.App||window.opener?.App;
     try{const cu=app&&app.m_CurrentUser;for(const b of [cu&&cu.strAccountBalance,cu&&cu.strAccountBalancePending])
      if(b&&b.trim()&&!BAL.has(b.trim())){BAL.add(b.trim());changed=true}}catch(e){}
     try{const fs=window.friendStore||window.opener?.friendStore;const u=fs&&fs.m_FriendsUIFriendStore;const p=u&&u.m_self&&u.m_self.m_persona;
      const acct=app&&app.m_CurrentUser&&app.m_CurrentUser.strAccountName;
      for(const n of [p&&p.m_strPlayerName,acct])if(learnName(n,ME_NAME,true))changed=true;
      if(p&&p.m_strAvatarHash&&p.m_strAvatarHash!==DEFAULT_AV&&!hashes.has(p.m_strAvatarHash)){hashes.set(p.m_strAvatarHash,ME);changed=true}}catch(e){}
     try{const pic=document.querySelector("#global_actions .user_avatar img");const h=pic&&HASH.exec(pic.getAttribute("src")||"");
      if(h&&h[0]!==DEFAULT_AV&&!hashes.has(h[0])){hashes.set(h[0],ME);changed=true}
      const pull=document.getElementById("account_pulldown");if(pull&&learnName(pull.textContent,ME_NAME,true))changed=true;
      const wallet=document.getElementById("header_wallet_balance");const b=wallet&&wallet.textContent.trim();
      if(b&&!BAL.has(b)){BAL.add(b);changed=true}}catch(e){}
     if(changed)rebuild();return changed}
    
    function learnFriends(){let list;try{const fs=window.friendStore||window.opener?.friendStore;const u=fs.m_FriendsUIFriendStore;
      const me=u&&u.m_self&&u.m_self.m_unAccountID;const fr=fs.allFriends||[];const ids=new Set(fr.map(f=>f.m_unAccountID));
      const pool=new Map();if(u&&u.m_mapPlayerCache)for(const p of u.m_mapPlayerCache.values())if(p)pool.set(p.m_unAccountID,p);
      try{const app=window.g_FriendsUIApp||window.opener?.g_FriendsUIApp;for(const g of app.m_ChatStore.m_mapChatGroups.values()){
       const accts=new Set(g.m_rgGroupMembersSummary||[]);try{for(const k of g.m_groupMembers.keys())accts.add(Number(k))}catch(e){}
       for(const a of accts){if(!pool.has(a)){try{const p=app.m_FriendStore.GetPlayer(a);if(p)pool.set(a,p)}catch(e){}}}}}catch(e){}
      const others=[...pool.values()].filter(p=>p&&p.m_persona&&p.m_persona.m_strPlayerName&&!ids.has(p.m_unAccountID)&&p.m_unAccountID!==me);
      list=fr.concat(others.sort((a,b)=>a.m_unAccountID-b.m_unAccountID).map(p=>Object.assign(Object.create(p),{__other:1})))}catch(e){}
     if(!list||!list.length)return false;
     const rank=f=>{if(f.__other)return 3;const p=f.m_persona||{};return p.m_unGamePlayedAppID?0:(p.m_ePersonaState?1:2)};
     const fresh=list.filter(f=>!seen.has(f.m_unAccountID)).sort((a,b)=>rank(a)-rank(b)||a.m_unAccountID-b.m_unAccountID);
     for(const f of fresh)seen.set(f.m_unAccountID,seen.size);
     let changed=false;
     for(const f of list){const i=seen.get(f.m_unAccountID);const fake=ROSTER[i%ROSTER.length];
      const label=i<ROSTER.length?fake:fake+" "+(Math.floor(i/ROSTER.length)+1);const p=f.m_persona||{};
      for(const n of [p.m_strPlayerName,f.m_strNickname])if(learnName(n,label,false))changed=true;
      if(p.m_strAvatarHash&&p.m_strAvatarHash!==DEFAULT_AV&&!hashes.has(p.m_strAvatarHash)){hashes.set(p.m_strAvatarHash,pictureOf(fake));changed=true}}
     if(changed)rebuild();return changed}
    
    rebuild();
    const rep=s=>s.replace(RX,m=>{const v=names.get(m.toLowerCase())||m;return m.length>1&&m===m.toUpperCase()&&m!==m.toLowerCase()?v.toUpperCase():v});
    const hit=s=>{RX.lastIndex=0;const r=RX.test(s);RX.lastIndex=0;return r};
    const hashIn=s=>{for(const [h,u] of hashes)if(s.includes(h))return u;return null};
    const ATTRS=["src","srcset","title","alt","aria-label","placeholder","data-tooltip-text","style"];
    function fixText(t){const v=t.nodeValue;if(!v)return;const p=t.parentNode;if(p&&(p.nodeName==="STYLE"||p.nodeName==="SCRIPT"||p.nodeName==="TEXTAREA"))return;
     for(const b of BAL)if(v.includes(b)){const rest=v.split(b).join("").replace(/\(\s*\)/g,"");t.nodeValue=rest;
      if(!rest.trim()&&p&&p.nodeType===1&&p.childNodes.length===1)p.style.display="none";return}
     const tv=v.trim();const x=EXACT.get(tv.toLowerCase());
     if(x){t.nodeValue=v.replace(tv,tv===tv.toUpperCase()&&tv!==tv.toLowerCase()?x.toUpperCase():x);return}
     if(hit(v))t.nodeValue=rep(v)}
    function fixEl(e){if(!e.getAttribute)return;for(const a of ATTRS){const v=e.getAttribute(a);if(!v)continue;const u=hashIn(v);
      if(u){const next=a==="style"?v.replace(/url\([^)]*\)/g,m=>hashIn(m)?'url("'+u+'")':m):u;if(next!==v)e.setAttribute(a,next)}
      else if(a!=="src"&&a!=="srcset"&&a!=="style"&&hit(v))e.setAttribute(a,rep(v))}
     if(e.tagName==="INPUT"&&e.value&&hit(e.value))e.value=rep(e.value)}
    function fixTree(n){if(n.nodeType===3)return fixText(n);if(n.nodeType!==1&&n.nodeType!==9)return;
     const root=n.nodeType===9?n.documentElement:n;if(!root)return;fixEl(root);root.querySelectorAll("*").forEach(fixEl);
     const w=(n.ownerDocument||n).createTreeWalker(root,4);let t;while((t=w.nextNode()))fixText(t)}
    
    function favRows(doc){for(const row of doc.querySelectorAll(".friend.ingame")){const holder=row.querySelector(".labelHolder");
      if(!holder||holder.children.length<2)continue;const nameEl=holder.children[0].firstElementChild;if(!nameEl)continue;
      const label=nameEl.textContent.trim().replace(/ \d+$/,"");if(!ROSTER.includes(label))continue;
      const [game,cover]=FAV[label]||FAV_DEFAULT;const icon=cover||pictureOf(game);
      const line=holder.children[1];const g=line.firstElementChild;if(g&&g.textContent!==game)g.textContent=game;
      for(const extra of [...line.children].slice(1))if(extra.style.display!=="none")extra.style.display="none";
      const ic=row.querySelector("img.gameIcon");if(ic&&ic.getAttribute("src")!==icon){ic.setAttribute("src",icon);ic.style.objectFit="cover"}}}
    const docs=new Set();
    function watch(doc){if(!doc||!doc.documentElement||docs.has(doc))return;docs.add(doc);fixTree(doc);
     new MutationObserver(ms=>{for(const m of ms){if(m.type==="characterData")fixText(m.target);else if(m.type==="attributes")fixEl(m.target);else m.addedNodes.forEach(fixTree)}
      favRows(doc);if(hit(doc.title))doc.title=rep(doc.title)}).observe(doc,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:ATTRS});
     if(hit(doc.title))doc.title=rep(doc.title)}
    function tick(){const grew=learnSelf()|learnFriends();
     if(grew)for(const d of docs){try{fixTree(d)}catch(e){}}
     watch(document);favRows(document);try{for(const p of g_PopupManager.m_mapPopups.values()){try{watch(p.m_popup.document);favRows(p.m_popup.document)}catch(e){}}}catch(e){}}
    if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",tick);else tick();setInterval(tick,400);
    """#
}
