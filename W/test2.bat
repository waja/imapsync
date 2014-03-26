
REM $Id: test2.bat,v 1.15 2013/05/06 08:15:39 gilles Exp gilles $
REM

cd C:\msys\1.0\home\Admin\imapsync
REM perl ./imapsync --host1 p  --user1 tata --passfile1 secret.tata  --host2 p --user2 titi --passfile2 secret.titi --delete2 --expunge2 --folder INBOX 
REM perl ./imapsync --host1 p  --user1 tata --passfile1 secret.tata  --host2 p --user2 titi --passfile2 secret.titi --delete2 --expunge1 --expunge2 --folder INBOX --usecache  

REM imapsync --host1 p --user1 tata --passfile1 secret.tata --host2 p --user2 titi --passfile2 secret.titi --justfolders --nofoldersize --folder INBOX.yop.yap --sep1 / --regextrans2 "s,/,_," 
REM imapsync --host1 p --user1 tata --passfile1 secret.tata --host2 p --user2 titi --passfile2 secret.titi --nofoldersize --folder INBOX.yop.yap --regexflag 's/\\Answered//g' --debug > out.txt  

REM perl imapsync --version
REM perl imapsync --tests_debug

REM imapsync.exe ^
REM   --host1 p --user1 big1 --passfile1 secret.big1 ^
REM   --host2 p --user2 big2 --passfile2 secret.big2 ^
REM   --folder INBOX.bigmail

REM perl imapsync 
REM perl imapsync --host1 p --user1 tata --passfile1 secret.tata --host2 p --user2 titi --passfile2 secret.titi --nofoldersize --folder INBOX.yop.yap --regexflag "s/\\ /\\/g" --debugflags

REM FOR /F "tokens=1,2,3,4 delims=; eol=#" %%G IN (file.txt) DO imapsync ^
REM --host1 imap.side1.org --user1 %%G --password1 %%H ^
REM --host2 imap.side2.org --user2 %%I --password2 %%J

REM imapsync --host1 p --user1 tata   --passfile1 secret.tata ^
REM          --host2 p --user2 dollar --password2 "$%%&<>|^"^" --justlogin

REM imapsync --host1 p --user1 tata   --passfile1 secret.tata ^
REM         --host2 p --user2 equal --password2 "==lalala" --justlogin --debugimap2

REM perl ./imapsync --host1 p --user1 tata --passfile1 secret.tata ^
REM               --host2 p --user2 titi --passfile2 secret.titi ^
REM               --folder INBOX.useuid --useuid --debugcache --delete2


REM perl ./imapsync --host1 p --user1 tata --passfile1 secret.tata ^
REM             --host2 imap.gmail.com --ssl2 --user2 gilles.lamiral@gmail.com --passfile2 secret.gilles_gmail ^
REM             --usecache --nofoldersizes --folder INBOX --regextrans2 "s(INBOX)([Gmail]/te*st)" 

REM perl ./imapsync --host1 imap.gmail.com --port1 993  --ssl1 --host2 imap.bigs.dk --justconnect

REM imapsync.exe --host1 imap.gmail.com --port1 993  --ssl1 --host2 imap.bigs.dk --justconnect

REM @echo off

SET csvfile=file.txt

DATE /t
TIME /t

FOR /f "tokens=1-4 delims=-/: " %%a IN ('DATE /t') DO (SET mydate=%%c_%%a_%%b_%%d)
FOR /f "tokens=1-2 delims=-/: " %%a IN ('TIME /t') DO (SET mytime=%%a_%%b)
ECHO %mydate%_%mytime%

if not exist LOG mkdir LOG
FOR /F "tokens=1,2,3,4 delims=; eol=#" %%G IN (%csvfile%) DO ECHO syncing to user %%I & imapsync ^
  --host1 imap.side1.org --user1 %%G --password1 %%H ^
  --host2 imap.side2.org --user2 %%I --password2 %%J ^
  > LOG\log_%%I_%mydate%_%mytime%.txt 2>&1

ECHO Loop finished
ECHO log files are in LOG directory
PAUSE
