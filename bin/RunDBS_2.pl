#!/usr/bin/env perl
# This pipeline takes PSI templates and adds PSIs from new samples.
use warnings;
use strict;
use Cwd qw(abs_path);
use Getopt::Long;
use File::Copy 'move';

# INITIALIZE
my $binPath = abs_path($0);
$0 =~ s/^.*\///;
$binPath =~ s/\/$0$//;

my $sp;              #species Hsa no longer default
my $dbDir;

my $verboseFlag = 1;
my $helpFlag = 0;

my $globalLen = 50;  # testing? not file specific any longer --TSW

my $outDir="vast_out";
my $compress = 0;

my $noIRflag = 0;    # don't use IR!
my $onlyIRflag = 0; # only run intron retention
my $IR_version = 2;  # either 1 or 2
my $onlyEXflag = 0; # only run exon skipping
my $noANNOTflag = 0;
my $extra_eej = 5; # default extra eej to use in ANNOT and in COMBI if use_all_excl_eej is provided
my $use_all_excl_eej = 0; # for COMBI flag

my $cRPKMCounts = 0; # print a second cRPKM summary file containing read counts
my $normalize = 0; # gets an expression table with normalized values
my $install_limma = 0; # installs limma
my $noGEflag = 0;
my $onlyGEflag = 0;

my $asmbly;       # for human and mouse: vts formats the output wrt. hg19/hg3, mm9/mm10 depending on user's choice of argument -a
 
GetOptions("help"  	       => \$helpFlag,
	   "dbDir=s"           => \$dbDir,
	   "sp=s"              => \$sp,
	   "a=s"               => \$asmbly,
	   "verbose"           => \$verboseFlag,
	   "output=s"          => \$outDir,
	   "o=s"               => \$outDir,
           "z"                 => \$compress,
	   "noIR"              => \$noIRflag,
	   "onlyIR"            => \$onlyIRflag,
	   "onlyEX"            => \$onlyEXflag,
	   "noANNOT"           => \$noANNOTflag,
	   "IR_version=i"      => \$IR_version,
	   "extra_eej=i"       => \$extra_eej,
	   "use_all_excl_eej"  => \$use_all_excl_eej,
	   "exprONLY"          => \$onlyGEflag,
	   "no_expr"           => \$noGEflag,
           "C"                 => \$cRPKMCounts,
	   "norm"              => \$normalize,
	   "install_limma"     => \$install_limma);

our $EXIT_STATUS = 0;

sub sysErrMsg {
  my @sysCommand = (shift);
  not system(@sysCommand) or die "[vast combine error]: @sysCommand Failed in $0!";
}

sub errPrint {
  my $errMsg = shift;
  print STDERR "[vast combine error]: $errMsg\n";
  $EXIT_STATUS = 1;
}

sub errPrintDie {
  my $errMsg = shift;
  errPrint $errMsg;
  exit $EXIT_STATUS if ($EXIT_STATUS != 0);
}

sub verbPrint {
  my $verbMsg = shift;
  if($verboseFlag) {
    chomp($verbMsg);
    print STDERR "[vast combine]: $verbMsg\n";
  }
}

### Gets the version
my $version;
open (VERSION, "$binPath/../VERSION");
$version=<VERSION>;
chomp($version);
$version="No version found" if !$version;

if ($helpFlag or (!defined $sp)){
    print STDERR "
VAST-TOOLS v$version

Usage: vast-tools combine -o OUTPUTDIR -sp [Hsa|Mmu|etc] [options]

Combine multiple samples analyzed using \"vast-tools align\" into a single summary table. 

GENERAL OPTIONS:
	-o, --output 		Output directory to combine samples from (default vast_out)
				Must contain sub-folders to_combine or expr_out from align steps.
	-sp Hsa/Mmu/etc		Species selection (mandatory)
	-a			Genome assembly of the output coordinates (only for -sp Hsa or Mmu) 
				For -sp Hsa: hg19 or hg38, (default hg19)
				    - vast-tools works internally with hg19; 
                                      if you choose hg38, the output gets lifted-over to hg38
				For -sp Mmu: mm9 or mm10, (default mm9)
				    - vast-tools will work internally with mm9; 
                                      if you choose mm10, the output gets lifted-over to mm10
	--dbDir DBDIR	        Database directory
	-z			Compress all output files using gzip
	-v, --verbose		Verbose messages
	-h, --help		Print this help messagev

AS OPTIONS:
        --onlyEX                Only run the exon skpping pipelines (default off)
	--noIR			Don't run intron retention pipeline (default off)
        --onlyIR                Only run intron retention pipeline (default off) 
        --IR_version 1/2        Version of the IR analysis (default 2)
        --noANNOT               Don't use exons quantified directly from annotation (default off)
        --use_all_excl_eej      Use all exclusion EEJs (within extra_eej limit) in ss-based module (default off)
        --extra_eej i           Use +/- extra_eej neighboring junctions to calculate skipping in 
                                     ANNOT (from A) and splice-site-based (from C1/C2) modules (default 5)

GE OPTIONS:
        -no_expr                Does not create gene expression tables (default OFF)
        -exprONLY               Only creates gene expression tables (default OFF)
	-C			Create a cRPKM plus read counts summary table. By default, a
    				table containing ONLY cRPKM is produced. This option is only
           			applicable when expression analysis is enabled.
        --norm                  Create a cRPKM table normalized using 'normalizeBetweenArrays' from limma (default OFF)
        --install_limma         Installs limma package if needed for normalization (default OFF)


*** Questions \& Bug Reports: Manuel Irimia (mirimia\@gmail.com)
					\n";

  exit $EXIT_STATUS;
}

errPrintDie "Need output directory" unless (defined $outDir);
errPrintDie "The output directory $outDir does not exist" unless (-e $outDir);
errPrintDie "IR version must be either 1 or 2." if ($IR_version != 1 && $IR_version != 2);

# prints version (05/05/19)
verbPrint "VAST-TOOLS v$version";

if(!defined($dbDir)) {
  $dbDir = "$binPath/../VASTDB";
}
$dbDir = abs_path($dbDir);
$dbDir .= "/$sp";
errPrintDie "The database directory $dbDir does not exist" unless (-e $dbDir);
verbPrint "Using VASTDB -> $dbDir";

chdir($outDir);

mkdir("raw_incl") unless (-e "raw_incl"); # make new output directories.  --TSW
mkdir("raw_reads") unless (-e "raw_reads"); # ^

### Settings:
errPrintDie "Needs species 3-letter key\n" if !defined($sp);  #ok for now, needs to be better. --TSW

# if species is not human nor mouse, we override $asmbly ignoring potential user input
if($sp ne "Hsa" && $sp ne "Mmu"){$asmbly="";}
# get assembly specification for human and mouse
if( $sp eq "Hsa" ){if(!defined($asmbly)){$asmbly="hg19";}; unless($asmbly =~ /(hg19|hg38)/){errPrintDie "Specified assmbly $asmbly either unknown or inapplicable for species $sp\n"}}
if( $sp eq "Mmu" ){if(!defined($asmbly)){$asmbly="mm9";};  unless($asmbly =~ /(mm9|mm10)/){errPrintDie "Specified assmbly $asmbly either unknown or inapplicable for species $sp\n"}}
# we add leading "-" for convenience during defining output file name later 
if($asmbly ne ""){$asmbly="-".$asmbly;}

my @files;
my $N = 0;

if ($onlyIRflag){
    if ($IR_version == 1){
	@files=glob("to_combine/*IR"); #gathers all IR files
    }
    else {
	@files=glob("to_combine/*IR2"); #gathers all IR2 files
    }
    $N=$#files+1;
}
else {
   @files=glob("to_combine/*exskX"); #gathers all exskX files (a priori, simple).                                                                                                                                                                                                                                               
   $N=$#files+1;
}

### Creates the LOG
open (LOG, ">>VTS_LOG_commands.txt");
my $all_args="-sp $sp -o $outDir -IR_version $IR_version -extra_eej $extra_eej";
$all_args.=" -noIR" if $noIRflag;
$all_args.="  -onlyIR" if $onlyIRflag;
$all_args.=" -onlyEX" if $onlyEXflag;
$all_args.=" -noANNOT" if $noANNOTflag;
$all_args.=" -use_all_excl_eej" if $use_all_excl_eej;
$all_args.=" -exprONLY" if $onlyGEflag;
$all_args.=" -no_expr" if $noGEflag;
$all_args.=" -C" if $cRPKMCounts;
$all_args.=" -norm" if $normalize;

print LOG "[VAST-TOOLS v$version, ".&time."] vast-tools combine $all_args\n";

if ($N != 0 && !$onlyGEflag) {
    unless ($onlyIRflag || $onlyGEflag){
	### Gets the PSIs for the events in the a posteriori pipeline
	verbPrint "Building Table for COMBI (splice-site based pipeline)\n";
	sysErrMsg "$binPath/Add_to_COMBI.pl -sp=$sp -dbDir=$dbDir -len=$globalLen -verbose=$verboseFlag -use_all_excl_eej=$use_all_excl_eej -extra_eej=$extra_eej";
	
	### Gets the PSIs for the a priori, SIMPLE
	verbPrint "Building Table for EXSK (transcript-based pipeline, single)\n";
	sysErrMsg "$binPath/Add_to_APR.pl -sp=$sp -type=exskX -dbDir=$dbDir -len=$globalLen -verbose=$verboseFlag";
	
	### Gets the PSIs for the a priori, COMPLEX
	verbPrint "Building Table for MULTI (transcript-based pipeline, multiexon)\n";
	sysErrMsg "$binPath/Add_to_APR.pl -sp=$sp -type=MULTI3X -dbDir=$dbDir -len=$globalLen -verbose=$verboseFlag";
	
	### Gets the PSIs for the MIC pipeline
	verbPrint "Building Table for MIC (microexon pipeline)\n";
	sysErrMsg "$binPath/Add_to_MIC.pl -sp=$sp -dbDir=$dbDir -len=$globalLen -verbose=$verboseFlag";
    }

    #### New in v2.0 (added 15/01/18)
    unless ($noANNOTflag || $onlyIRflag || $onlyGEflag){
	### Gets the PSIs for ALL annotated exons directly
	verbPrint "Building Table for ANNOT (annotation-based pipeline)\n";
	sysErrMsg "$binPath/GetPSI_allannot_VT.pl -sp=$sp -dbDir=$dbDir -len=$globalLen -verbose=$verboseFlag -extra_eej=$extra_eej";
    }

    
    # To define version [02/10/15]; minimize changes for users
    # $v => "" or "_v2" [v1/v2]
    my $v;
    my @irFiles;
    if ($IR_version == 1){
	$v="";
	@irFiles = glob(abs_path("to_combine") . "/*.IR");
    }
    elsif ($IR_version == 2){
	$v="_v2";
	@irFiles = glob(abs_path("to_combine") . "/*.IR2");
    }
    
    $noIRflag = 1 if @irFiles == 0;

    unless($noIRflag || $onlyEXflag || $onlyGEflag) {
	### Gets the PIRs for the Intron Retention pipeline
	verbPrint "Building quality score table for intron retention (version $IR_version)\n";
	sysErrMsg "$binPath/RI_MakeCoverageKey$v.pl -sp $sp -dbDir $dbDir " . abs_path("to_combine");
	verbPrint "Building Table for intron retention (version $IR_version)\n";
	sysErrMsg "$binPath/RI_MakeTablePIR.R --verbose $verboseFlag -s $dbDir --IR_version $IR_version" .
	    " -c " . abs_path("to_combine") .
	    " -q " . abs_path("to_combine") . "/Coverage_key$v-$sp$N.IRQ" .
	    " -o " . abs_path("raw_incl");
    }

    unless ($onlyIRflag || $onlyEXflag || $onlyGEflag){
	### Gets PSIs for ALT5ss and adds them to the general database
	verbPrint "Building Table for Alternative 5'ss choice events\n";
	sysErrMsg "$binPath/Add_to_ALT5.pl -sp=$sp -dbDir=$dbDir -len=$globalLen -verbose=$verboseFlag";
	
	### Gets PSIs for ALT3ss and adds them to the general database
	verbPrint "Building Table for Alternative 3'ss choice events\n";
	sysErrMsg "$binPath/Add_to_ALT3.pl -sp=$sp -dbDir=$dbDir -len=$globalLen -verbose=$verboseFlag";
    }
    
    ### Combine results into unified "FULL" table
    verbPrint "Combining results into a single table\n";
    my @input;
    
    if ($onlyIRflag){
	@input = ("raw_incl/INCLUSION_LEVELS_IR-$sp$N.tab");
    }
    elsif ($onlyEXflag){
	@input =    ("raw_incl/INCLUSION_LEVELS_EXSK-$sp$N-n.tab",
		     "raw_incl/INCLUSION_LEVELS_MULTI-$sp$N-n.tab",
		     "raw_incl/INCLUSION_LEVELS_COMBI-$sp$N-n.tab",
		     "raw_incl/INCLUSION_LEVELS_MIC-$sp$N-n.tab");
	
	unless($noANNOTflag) { # for ANNOT Exons (EXi, i>=6) [v2.0]
	    push(@input, "raw_incl/INCLUSION_LEVELS_ANNOT-$sp$N-n.tab");
	}
    }
    else {
	@input =    ("raw_incl/INCLUSION_LEVELS_EXSK-$sp$N-n.tab",
		     "raw_incl/INCLUSION_LEVELS_MULTI-$sp$N-n.tab",
		     "raw_incl/INCLUSION_LEVELS_COMBI-$sp$N-n.tab",
		     "raw_incl/INCLUSION_LEVELS_MIC-$sp$N-n.tab",
		     "raw_incl/INCLUSION_LEVELS_ALT3-$sp$N-n.tab",
		     "raw_incl/INCLUSION_LEVELS_ALT5-$sp$N-n.tab");
	
	unless($noANNOTflag) { # for ANNOT Exons (EXi, i>=6) [v2.0]
	    push(@input, "raw_incl/INCLUSION_LEVELS_ANNOT-$sp$N-n.tab");
	}
	unless($noIRflag) {
	    push(@input, "raw_incl/INCLUSION_LEVELS_IR-$sp$N.tab");
	}
    }
    
    my $finalOutput = "INCLUSION_LEVELS_FULL-$sp$N$asmbly.tab";
    sysErrMsg "cat @input | $binPath/Add_to_FULL.pl -sp=$sp -dbDir=$dbDir " .
	"-len=$globalLen -verbose=$verboseFlag > $finalOutput";
    
    # lift-over if necessary (hg19->hg38 or mm9->mm10)
    if( $asmbly=~/(hg38|mm10)/ ){
    	# select liftOvr dictionary
    	my $dictionary="lftOvr_dict_from_hg19_to_hg38.pdat"; if($asmbly=~/mm10/){$dictionary="lftOvr_dict_from_mm9_to_mm10.pdat";}
    	# do liftOvr
    	sysErrMsg "$binPath/LftOvr_INCLUSION_LEVELS_FULL.pl translate $finalOutput $dbDir/FILES/$dictionary ${finalOutput}.lifted";
    	# move files
    	move("${finalOutput}.lifted","${finalOutput}");
    }
    
    verbPrint "Final table saved as: " . abs_path($finalOutput) ."\n";
    
    if ($compress) {
      verbPrint "Compressing files\n";
      sysErrMsg "gzip -v raw_incl/*.tab raw_reads/*.tab $finalOutput";
      $finalOutput .= ".gz";
    }
}

### Combine cRPKM files, if present
my @rpkmFiles=glob("expr_out/*.cRPKM"); 
unless ($noGEflag){
    if (@rpkmFiles > 0) {
	verbPrint "Combining cRPKMs into a single table\n";
	my $cRPKMOutput = "cRPKM-$sp" . @rpkmFiles . ".tab";
	my $cRPKMOutput_b = "cRPKM_AND_COUNTS-$sp" . @rpkmFiles . ".tab";
	my $cRPKMOutput_c = "cRPKM-$sp" . @rpkmFiles . "-NORM.tab";
	$cRPKMCounts = $cRPKMCounts ? "-C" : "";
	$normalize = $normalize ? "-norm" : "";
	$install_limma = $install_limma ? "-install_limma" : "";
	sysErrMsg "$binPath/MakeTableRPKMs.pl -sp=$sp -dbDir=$dbDir $cRPKMCounts $normalize $install_limma";
	
	if ($compress) {
	    verbPrint "Compressing files\n";
	    sysErrMsg "gzip -v expr_out/*.cRPKM $cRPKMOutput";
	    $cRPKMOutput .= ".gz";
	}
	
	verbPrint "Final cRPKM table saved as: " . abs_path($cRPKMOutput) . "\n";
	verbPrint "Final cRPKM and COUNTS table saved as: " . abs_path($cRPKMOutput_b) . "\n" if $cRPKMCounts;
	verbPrint "Final normalized cRPKM table saved as: " . abs_path($cRPKMOutput_c) . "\n" if $normalize;
    }
}

if ($N + @rpkmFiles == 0) {
    verbPrint "Could not find any files to combine. If they are compressed, please decompress them first.\n";
    verbPrint "The path specified by -o needs to contain the sub-folder to_combine or expr_out.\n";
    verbPrint "By default this is -o vast_out, which contains vast_out/to_combine.\n";
}

verbPrint "Completed " . localtime;

sub time {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
    $year += 1900;
    $mon += 1;
    my $datetime = sprintf "%04d-%02d-%02d (%02d:%02d)", $year, $mday, $mon, $hour, $min;
    return $datetime;
}
