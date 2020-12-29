@REM $Id: test_testsdebug.bat,v 1.4 2019/11/25 12:44:59 gilles Exp gilles $

@SETLOCAL
@ECHO OFF

ECHO Currently running through %0 %*

CD /D %~dp0

REM Remove the error file because its existence means an error occured during this script execution
IF EXIST LOG_bat\%~nx0.txt DEL LOG_bat\%~nx0.txt

@REM CALL :handle_error perl .\imapsync --justbanner
CALL :handle_error perl .\imapsync --testsdebug --debug
@REM CALL :handle_error perl .\imapsync --tests

@REM @PAUSE
@ENDLOCAL
@EXIT /B


:handle_error
SETLOCAL
ECHO IN %0 with parameters %*
%*
SET CMD_RETURN=%ERRORLEVEL%

IF %CMD_RETURN% EQU 0 (
        ECHO GOOD END
) ELSE (
        ECHO BAD END
        IF NOT EXIST LOG_bat MKDIR LOG_bat
        ECHO Failure running %* >> LOG_bat\%~nx0.txt
)
ENDLOCAL
EXIT /B

