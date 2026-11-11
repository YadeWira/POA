{ poa.inc — options shared by the whole Pascal layer.

  Every unit includes it and then checks that range and overflow checking
  are on, so removing them here stops the build. Validation works on
  arrays, never on raw pointers: $R+ does not check p[i] with p: PByte.
  Lengths and indices are signed (SizeInt); loops over arrays use High(). }

{$mode objfpc}
{$H+}
{$R+}
{$Q+}
{$modeswitch advancedrecords}
