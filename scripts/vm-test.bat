@echo off
rem POA on a real Windows: the command, libpoa (test_lib) and the 7-Zip plugin.
rem Folder layout: poa.exe poa.dll test_lib.exe 7z\ s\ (samples). Prints PASS or FAIL lines.
rem From PPA's test.bat. scripts/vm-kit.sh builds the folder from CI's binaries.
setlocal enabledelayedexpansion
cd /d %~dp0
set L=
for %%f in (s\*) do set L=!L! %%f
set FAILS=0

poa.exe --version
if errorlevel 1 (echo FAIL: --version & set /a FAILS+=1)

poa.exe selftest > selftest.txt 2>&1
if errorlevel 1 (type selftest.txt & echo FAIL: selftest & set /a FAILS+=1) else (echo PASS: selftest)

if exist o rmdir /s /q o
mkdir o
mkdir o\x
mkdir o\z
poa.exe a -q --output-dir=o %L%
if errorlevel 1 (echo FAIL: poa a & set /a FAILS+=1)
poa.exe t -q o\*.poa
if errorlevel 1 (echo FAIL: poa t & set /a FAILS+=1)
set P=
for %%f in (o\*.poa) do set P=!P! %%f
poa.exe x -q --output-dir=o\x !P!
if errorlevel 1 (echo FAIL: poa x & set /a FAILS+=1)
set BAD=0
for %%f in (s\*) do (
  fc /b "%%f" "o\x\%%~nxf" > nul 2>&1
  if errorlevel 1 (echo DIFF: %%~nxf & set /a BAD+=1)
)
if !BAD!==0 (echo PASS: poa a/t/x, every file back) else (echo FAIL: !BAD! files differ & set /a FAILS+=1)

poa.exe a -q -th 1 --output-dir=o\z s\vorbis_q6_44k_st.ogg
fc /b o\vorbis_q6_44k_st.ogg.poa o\z\vorbis_q6_44k_st.ogg.poa > nul 2>&1
if errorlevel 1 (echo FAIL: -th 1 writes other bytes & set /a FAILS+=1) else (echo PASS: -th 1 the same .poa)

test_lib.exe %L% > test_lib.txt 2>&1
if errorlevel 1 (type test_lib.txt & echo FAIL: test_lib & set /a FAILS+=1) else (echo PASS: test_lib & findstr /i "checks" test_lib.txt)

if not exist 7z\Codecs mkdir 7z\Codecs
copy /y poa.dll 7z\Codecs\poa.dll > nul
7z\7z.exe i | findstr 37F50
7z\7z.exe i | findstr 37F50 > nul
if errorlevel 1 (echo FAIL: 7-Zip does not list POA & set /a FAILS+=1)
7z\7z.exe a -bso0 -bsp0 -m0=POA -m1=LZMA2 -mmt=4 o\t.7z %L%
if errorlevel 1 (echo FAIL: 7z a & set /a FAILS+=1)
7z\7z.exe t -bso0 -bsp0 o\t.7z
if errorlevel 1 (echo FAIL: 7z t & set /a FAILS+=1)
7z\7z.exe x -bso0 -bsp0 -oo\7 o\t.7z
if errorlevel 1 (echo FAIL: 7z x & set /a FAILS+=1)
set BAD=0
for %%f in (s\*) do (
  fc /b "%%f" "o\7\s\%%~nxf" > nul 2>&1
  if errorlevel 1 (echo DIFF7: %%~nxf & set /a BAD+=1)
)
if !BAD!==0 (echo PASS: 7-Zip with POA, every file back) else (echo FAIL: !BAD! files differ after 7-Zip & set /a FAILS+=1)
for %%a in (o\t.7z) do echo 7z archive: %%~za bytes
echo FAILS: !FAILS!
