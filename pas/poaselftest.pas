{ Ported from PJA's pas/pjaselftest.pas via PMPA (pas/pmpaselftest.pas).

  poa selftest (doc/CLI.md): the samples inside the binary
  (poaselftest.inc, written by tools/gen_selftest.py from tests/ogg: two
  small Vorbis files, which go through the Vorbis model, and an Opus one,
  coded as bytes) compressed and extracted. Each .poa has to be the very
  bytes the include names (its size and BLAKE3-128), and each has to come
  back as its sample. The format is frozen within a version: those bytes
  do not change with the platform, the compiler's optimisation or the
  threads. POA has one path (plain), so --cpu=plain changes nothing. }
unit poaselftest;

{$I poa.inc}
{$ifopt R-}{$fatal poaselftest: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poaselftest: overflow checks ($Q+) are mandatory}{$endif}

interface

uses poasysinfo;

{ Prints a line per sample and a summary (only failures and the summary
  with quiet). 0 when every check passed, 1 if not. }
function RunSelftest(quiet: Boolean; onePath: Boolean = False; only: TCpuPath = cpPlain): Integer;

implementation

uses SysUtils, poablake3, poapack, poainfo;

{$I poaselftest.inc}

function SameBytes(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

function RunSelftest(quiet: Boolean; onePath: Boolean; only: TCpuPath): Integer;
var k, checks, failed: Integer; data, got, back: TBytes; r: TPackResult; h: THash16; why, hex: string;
begin
  checks := 0; failed := 0;
  if not quiet then
    Writeln('poa selftest: ', SELFTEST_COUNT, ' samples inside the binary, on the path ',
            CPU_PATH_NAMES[only], ' (the only one POA has)');
  for k := 0 to SELFTEST_COUNT - 1 do begin
    SelftestSample(k, data, h);
    hex := HexBytes(h);
    Inc(checks);
    why := '';
    try
      r := Pack(data, got, True);
      if not r.Ok then why := 'compress failed: ' + r.Text
      else if (Length(got) <> SELFTEST_POA_SIZE[k]) or (HexBytes(Blake3_128(got)) <> hex) then
        why := 'a different .poa: ' + IntToStr(Length(got)) + ' B, blake3-128 ' + HexBytes(Blake3_128(got)) +
               ' (expected ' + IntToStr(SELFTEST_POA_SIZE[k]) + ' B, ' + hex + ')';
      if why = '' then begin
        r := Unpack(got, QWord(Length(data)), back, h);
        if not r.Ok then why := 'extract failed: ' + r.Text
        else if not SameBytes(back, data) then why := 'extracted to other bytes';
      end;
    except
      on e: Exception do why := 'internal error: ' + e.ClassName + ': ' + e.Message;
    end;
    if why <> '' then begin
      Inc(failed);
      Writeln(StdErr, 'poa: selftest: ', SELFTEST_NAMES[k], ': ', why);
    end else if not quiet then
      Writeln('  ', SELFTEST_NAMES[k], ': ', Length(data), ' B -> ', Length(got), ' B, .poa blake3-128 ', hex,
              ': ok');
  end;
  if failed = 0 then begin
    Writeln('selftest: ', checks, ' of ', checks, ' checks passed on 1 path(s) (', CPU_PATH_NAMES[only],
            '): every .poa the expected bytes, every sample back');
    Result := 0;
  end else begin
    Writeln(StdErr, 'poa: selftest: ', failed, ' of ', checks, ' checks FAILED. This is a bug in POA: please run',
            ' poa report and open an issue at ', ISSUES_URL);
    Result := 1;
  end;
end;

end.
