#!/usr/bin/env python3
# dedup-chats.py — merge duplicate 1:1 chats in a DECRYPTED Viber db (plaintext).
# A duplicate = two ChatInfo rows with the same participant set (same {self, contact}).
# Keeps the chat with the most recent message; repoints Events/Reminders; deletes the rest.
#
#   python3 dedup-chats.py <decrypted.db>
#
# To put the result back into Viber you must re-encrypt with the Linux key/scheme and
# reinstall — see INTERNALS.md ("Putting data back").
import sqlite3, sys
if len(sys.argv)!=2: sys.exit("usage: dedup-chats.py <decrypted.db>")
db=sqlite3.connect(sys.argv[1]); c=db.cursor()
c.execute("""WITH p AS (SELECT ChatID, group_concat(ContactID) ids FROM
   (SELECT ChatID,ContactID FROM ChatRelation ORDER BY ChatID,ContactID) GROUP BY ChatID)
   SELECT ids, group_concat(ChatID) FROM p GROUP BY ids HAVING count(*)>1""")
groups=[[int(x) for x in cids.split(',')] for _,cids in c.fetchall()]
merged=moved=0
for chatids in groups:
    best=max(chatids, key=lambda ch:((c.execute("SELECT max(TimeStamp) FROM Events WHERE ChatID=?",(ch,)).fetchone()[0] or 0), ch))
    for o in [x for x in chatids if x!=best]:
        moved += c.execute("SELECT count(*) FROM Events WHERE ChatID=?",(o,)).fetchone()[0]
        c.execute("UPDATE Events SET ChatID=? WHERE ChatID=?", (best,o))
        c.execute("UPDATE Reminders SET ChatID=? WHERE ChatID=?", (best,o))
        c.execute("DELETE FROM ChatRelation WHERE ChatID=?", (o,))
        c.execute("DELETE FROM ChatInfo WHERE ChatID=?", (o,))
        merged+=1
db.commit()
print(f"merged {merged} duplicate chats ({len(groups)} groups), moved {moved} events")
print("integrity:", c.execute("PRAGMA integrity_check").fetchone()[0])
db.close()
