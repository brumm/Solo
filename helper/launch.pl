# Loads SoloHelper.dylib into this (Apple-signed) perl process and runs it.
use strict;
use DynaLoader;
my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die "load failed: " . DynaLoader::dl_error() . "\n";
my $s = DynaLoader::dl_find_symbol($h, "solo_helper_main") or die "symbol missing\n";
DynaLoader::dl_install_xsub("main::run", $s);
run();
