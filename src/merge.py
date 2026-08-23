#!/usr/bin/env python3
# merge.py — merge one decrypted Viber db into another.
#   merge.py <base.db> <add.db> <out.db>
# <base> is kept as the authoritative install (its schema, its rows, its IDs are preserved);
# every message from <add> that <base> doesn't already have (by Events.Token) is appended,
# with add's chat/contact IDs remapped onto base's via same-Token overlap + Contact MID/Number.
# New conversations/contacts that exist only in <add> are imported with fresh IDs.
# Result is a plaintext db; re-encrypt with the target install's key to put it back.
import sqlite3, sys, os
if len(sys.argv)!=4: sys.exit("usage: merge.py <base.db> <add.db> <out.db>")
BASE, ADD, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
for x in (OUT, OUT+"-wal", OUT+"-shm", OUT+"-journal"):
    if os.path.exists(x): os.remove(x)

base=sqlite3.connect(BASE)
schema=base.execute("SELECT type,name,sql FROM sqlite_master WHERE sql NOT NULL AND name NOT LIKE 'sqlite_%'").fetchall()
base.close()
out=sqlite3.connect(OUT)
for t,n,s in schema:            # 1) tables of the base schema
    if t=='table': out.execute(s)
out.commit()
def cols(con,t): return [r[1] for r in con.execute(f'PRAGMA table_info("{t}")').fetchall()]
tables=[n for (t,n,s) in schema if t=='table']
q=lambda c: ",".join(f'"{x}"' for x in c)

out.execute("ATTACH ? AS base",(BASE,)); out.execute("ATTACH ? AS add_",(ADD,))
for t in tables:                # 2) copy ALL base rows (base IDs preserved)
    c=cols(out,t); out.execute(f'INSERT INTO main."{t}" ({q(c)}) SELECT {q(c)} FROM base."{t}"')
out.commit()
def mx(t,c): return (out.execute(f'SELECT max("{c}") FROM main."{t}"').fetchone()[0] or 0)
nE,nC,nK = mx("Events","EventID")+1, mx("Contact","ContactID")+1, mx("ChatInfo","ChatID")+1

# 3) id maps: add -> base
chatmap={}; contactmap={}
for a,b in out.execute("SELECT DISTINCT a.ChatID,b.ChatID FROM add_.Events a JOIN base.Events b ON a.Token=b.Token AND a.Token<>0"): chatmap.setdefault(a,b)
for a,b in out.execute("SELECT DISTINCT a.ContactID,b.ContactID FROM add_.Events a JOIN base.Events b ON a.Token=b.Token AND a.Token<>0"):
    if a and b: contactmap.setdefault(a,b)
for a,b in out.execute("SELECT a.ContactID,b.ContactID FROM add_.Contact a JOIN base.Contact b ON a.MID=b.MID WHERE a.MID IS NOT NULL AND a.MID NOT IN ('','0')"): contactmap.setdefault(a,b)
for a,b in out.execute("SELECT a.ContactID,b.ContactID FROM add_.Contact a JOIN base.Contact b ON a.Number=b.Number WHERE a.Number IS NOT NULL AND a.Number<>''"): contactmap.setdefault(a,b)

ccols=cols(out,"Contact")
def imp_contact(a):
    global nC
    if a in contactmap: return contactmap[a]
    if not a: return a
    r=out.execute(f'SELECT {q(ccols)} FROM add_.Contact WHERE ContactID=?',(a,)).fetchone()
    if not r: contactmap[a]=0; return 0
    d=dict(zip(ccols,r)); d["ContactID"]=nC; nC+=1
    out.execute(f'INSERT INTO main.Contact ({q(ccols)}) VALUES ({",".join("?"*len(ccols))})',[d[x] for x in ccols])
    contactmap[a]=d["ContactID"]; return d["ContactID"]
icols=cols(out,"ChatInfo"); rcols=cols(out,"ChatRelation")
def imp_chat(a):
    global nK
    if a in chatmap: return chatmap[a]
    r=out.execute(f'SELECT {q(icols)} FROM add_.ChatInfo WHERE ChatID=?',(a,)).fetchone()
    nid=nK; nK+=1; chatmap[a]=nid
    if r:
        d=dict(zip(icols,r)); d["ChatID"]=nid
        out.execute(f'INSERT INTO main.ChatInfo ({q(icols)}) VALUES ({",".join("?"*len(icols))})',[d[x] for x in icols])
    for rr in out.execute(f'SELECT {q(rcols)} FROM add_.ChatRelation WHERE ChatID=?',(a,)).fetchall():
        d=dict(zip(rcols,rr)); d["ChatID"]=nid
        if d.get("ContactID"): d["ContactID"]=imp_contact(d["ContactID"])
        out.execute(f'INSERT INTO main.ChatRelation ({q(rcols)}) VALUES ({",".join("?"*len(rcols))})',[d[x] for x in rcols])
    return nid

# 4) add-only events (Token not already in base)
base_tok=set(r[0] for r in out.execute("SELECT Token FROM base.Events WHERE Token<>0"))
ecols=cols(out,"Events"); eventmap={}; imported=0
for r in out.execute(f'SELECT {q(ecols)} FROM add_.Events WHERE Token<>0').fetchall():
    d=dict(zip(ecols,r))
    if d["Token"] in base_tok: continue
    eventmap[d["EventID"]]=nE; d["EventID"]=nE; nE+=1
    if d["ChatID"]:    d["ChatID"]=imp_chat(d["ChatID"])
    if d["ContactID"]: d["ContactID"]=imp_contact(d["ContactID"])
    out.execute(f'INSERT INTO main.Events ({q(ecols)}) VALUES ({",".join("?"*len(ecols))})',[d[x] for x in ecols]); imported+=1

# 5) child tables of imported events
for t in ["Messages","Calls","DownloadFile","UploadFile","EventsMetaData"]:
    if t not in tables: continue
    c=cols(out,t)
    for r in out.execute(f'SELECT {q(c)} FROM add_."{t}"').fetchall():
        d=dict(zip(c,r))
        if d.get("EventID") in eventmap:
            d["EventID"]=eventmap[d["EventID"]]
            out.execute(f'INSERT INTO main."{t}" ({q(c)}) VALUES ({",".join("?"*len(c))})',[d[x] for x in c])
if "Reminders" in tables:
    c=cols(out,"Reminders")
    for r in out.execute(f'SELECT {q(c)} FROM add_.Reminders').fetchall():
        d=dict(zip(c,r))
        if d.get("EventID") in eventmap:
            d["EventID"]=eventmap[d["EventID"]]; d["ChatID"]=chatmap.get(d.get("ChatID"),d.get("ChatID"))
            out.execute(f'INSERT INTO main.Reminders ({q(c)}) VALUES ({",".join("?"*len(c))})',[d[x] for x in c])
if "LikeRelation" in tables:
    c=cols(out,"LikeRelation")
    for r in out.execute(f'SELECT {q(c)} FROM add_.LikeRelation').fetchall():
        d=dict(zip(c,r))
        if d.get("LikeEventID") in eventmap:
            d["LikeEventID"]=eventmap[d["LikeEventID"]]
            try: out.execute(f'INSERT INTO main.LikeRelation ({q(c)}) VALUES ({",".join("?"*len(c))})',[d[x] for x in c])
            except Exception: pass
out.commit(); out.execute("DETACH base"); out.execute("DETACH add_")
for t,n,s in schema:            # 6) indexes/triggers/views AFTER data
    if t!='table': out.execute(s)
out.commit()
print(f"merged: +{imported} messages from add. totals -> events={mx('Events','EventID') and out.execute('SELECT count(*) FROM Events').fetchone()[0]}, messages={out.execute('SELECT count(*) FROM Messages').fetchone()[0]}, chats={out.execute('SELECT count(*) FROM ChatInfo').fetchone()[0]}")
print("integrity:", out.execute("PRAGMA integrity_check").fetchone()[0])
out.close()
