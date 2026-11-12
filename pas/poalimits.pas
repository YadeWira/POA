{ Ported from PJA's pas/pjalimits.pas via PMPA (pas/pmpalimits.pas).

  The limits the command applies, in one place. }
unit poalimits;

{$I poa.inc}
{$ifopt R-}{$fatal poalimits: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poalimits: overflow checks ($Q+) are mandatory}{$endif}

interface

const
  { x's --max-output by default: the largest original it extracts }
  DEFAULT_MAX_OUTPUT = 256 * 1024 * 1024;

  { the largest input read whole into memory (a file is held whole) }
  MAX_INPUT = QWord(1) shl 31;

  { How many times its payload a declared original size may be, so that a
    tiny file cannot declare a huge output before anything is decoded. A
    last-resort cap, PJA's; the user's --max-output still applies. }
  MAX_EXPANSION_RATIO = 65536;

implementation

end.
