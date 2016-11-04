#!/usr/bin/perl

use warnings;
use strict;

use Carp qw(confess);
use Data::Dumper;
use Getopt::Long;
use Image::Size;
use IPC::Run3 qw(run3);
use Time::Local;
use Image::ExifTool qw(:Public);
use Image::Magick;

my $WIDTH = 800;
my $HEIGHT = 450 ;

my $DIR_TMP = "/var/tmp/img";
my $VIDEO_DURATION = 10;
my $AUDIO_FILE;
my $DEPTH = 12;
my $FRAME_RATE = 24;
my $FPS_SLOW = 18;
my $SLOW;
my $TIDY;
my $HELP;
my ($VERBOSE, $DEBUG) = ( 0 );
my $INFO;
my $FONT_COLOR = 'white';
my $SHOW_DATES;
my $SHOW_GROUPS;
my $AUDIO_START;
$VERBOSE = 1 if $ENV{TERM};
my @PREFERRED_FORMATS = qw(yuv420p);
my $SORT_BY_NAME = 1;
my $SLOW_PICS;

GetOptions(
     'audio=s' => \$AUDIO_FILE
    ,'width=s' => \$WIDTH
    ,'fps-slow=s' => \$FPS_SLOW
    ,'audio-start=s' => \$AUDIO_START
    ,'video-duration=s' => \$VIDEO_DURATION
   ,'verbose+' => \$VERBOSE
   ,'show-dates' => \$SHOW_DATES
   ,'show-groups' => \$SHOW_GROUPS
   ,'sort-by-name' => \$SORT_BY_NAME
   ,'slow-pics'=> \$SLOW_PICS
        ,info  => \$INFO
       ,debug  => \$DEBUG
        ,slow  => \$SLOW
        ,tidy  => \$TIDY
        ,help  => \$HELP
) or exit;

die "Missing audio file '$AUDIO_FILE"
    if $AUDIO_FILE && !-e $AUDIO_FILE;# || !stat($AUDIO_FILE);

if ($AUDIO_START && !$AUDIO_FILE) {
    warn "ERROR: Audio start requires audio input\n";
    $HELP=1;
}
if ($HELP) {
    my ($me) = $0 =~ m{.*/(.*)};
    print "$me [--help] [--width=$WIDTH] [--slow] [--tidy]"
        ." [--audio=file] directory"
        ."\n"
        ."\t--width : output width, height is scaled in 1200x720\n"
        ."\t--slow : videos are played in slow motion at 'fps-slow' fps\n"
        ."\t--fps-slow : frames per second when slow motion, defaults "
            ."to $FPS_SLOW\n"
        ."\t--tidy : tries to group videos and pictures\n"
        ."\t--video-duration : trims videos to this duration, defaults "
            ."to $VIDEO_DURATION\n"
        ."\t--audio: add this audio file to the final video\n"
        ."\t--audio-start: seeks in the input audio file to position\n"
        ."\t--info: add info about the original file in each frame\n"
        ."\t--show-dates: show found dates for the found files\n"
        ."\t--show-groups: show how we files are being grouped\n"
        ."\t--sort-by-name: sorts the pictures and videos by name\n"
    ;
    exit;
}
$HEIGHT = int($WIDTH * 720 /1200);

my %EXT_IMG = map { lc($_) => 1 } qw( jpg png gif );
my %EXT_VIDEO = map { lc($_) => 1 } qw( mov 3gp mp4 ts avi);

my %COUNT;
my @ENCODER;
my $DRAWTEXT;

##############################################

sub show_dates {
    my $files = shift;
    for my $file ( sort { $files->{$a}->{date} <=> $files->{$b}->{date} } keys %$files ) {
        my ($name) = $file =~ m{.*/(.*)};
        print "$name : ".localtime($files->{$file}->{date})."\n";
    }
    exit;
}

sub exif_date {
    my $file = shift;
    my $info = exif_info($file) or return;
    my $date = ($info->{MediaCreateDate} || $info->{CreateDate} || $info->{ModifyDate});
       

    die "No date in exif ".Dumper($info) if !$date;
    my ($y,$month,$day, $h,$min,$s) 
        = $date =~ /(\d+):(\d+):(\d+) (\d+):(\d+):(\d+)/;

    return if !$date || $date =~ /^0000/;
    die "No info from '$date'" if !$y;
    die "No month from '$date'" if !$month;
    $month--;
    my $time = timelocal($s, $min, $h, $day, $month, $y);

    return $time;
}

sub exif_info{
    my $file = shift;
    my $info = ImageInfo($file);
    for (keys %$info) {
        delete $info->{$_} if !/date/i;
    }
    return $info;
}


sub list_files {
    my $dir = shift;

    opendir my $ls,$dir or die "$! $dir";

    my %pic;
    while ( my $name = readdir $ls) {
        my $file = "$dir/$name";
        my ($ext) = $file =~ m{.*\.(\w+)$};
        next if !$ext;
        next if !$EXT_IMG{lc($ext)}
            && !$EXT_VIDEO{lc($ext)};
        next if ! -f $file;

        my $date = $name;
        if (!$SORT_BY_NAME) {
            $date = exif_date($file);# if $EXT_IMG{lc($ext)};
            if (!$date) {
                my @stat = stat($file) or die "I can't stat $file";
                $date = $stat[9];
            }
        }
        $pic{$file} = { date => $date};
    }
    return \%pic;
}

sub convert_ts {
    my $video_in = shift;
    confess "Missing video in" if !$video_in;
    my $n = shift;

    my $video_out = tmp_file($n,'ts');
    return $video_out if -f $video_out && -s $video_out;

    my @cmd = ( 'ffmpeg' );

    push @cmd,('-r', $FPS_SLOW) if $SLOW;

    push @cmd,(
        '-i', $video_in
        ,'-vf','fade=in:0:20'
        ,'-f','mpegts'
        ,@ENCODER
        ,'-strict','experimental'
        ,'-s',"${WIDTH}x$HEIGHT"
        );

    my ($label) = $video_in =~ m{.*/(.*)};
    $label = $video_in if !$label;
    push @cmd,("-vf","$DRAWTEXT=text=$label:fontsize=50:fontcolor=$FONT_COLOR")   if $INFO;
    push @cmd,('-t',$VIDEO_DURATION)    if $VIDEO_DURATION;
    push @cmd,('-an')                   if $SLOW;
    push @cmd,(
        '-y'
        ,$video_out
    );
    my ($in, $out, $err);
    print("Converting $video_in to ts\n")   if $VERBOSE;
    print join(" ",@cmd)."\n"               if $DEBUG;
    run3(\@cmd, \$in, \$out, \$err);
    die $err if $?;
    return $video_out;
}

sub create_inputs {
    my $files = shift;

    my $file_out = "$DIR_TMP/$$.txt";

    open my $out,'>',$file_out or die "$! $file_out";
    print $out join("\n",map {" file '$_'" if !ref $_ } @$files)."\n";
    close $out;

    return $file_out;
}
sub join_videos {
    my $files = shift;
    my $file_out = shift;

    my $file_inputs = create_inputs($files);
    my @cmd = ('ffmpeg' );
    push @cmd,('-ss',$AUDIO_START)  if $AUDIO_START;
    push @cmd,('-i',$AUDIO_FILE ) if $AUDIO_FILE;
#        ,'"concat:'.join("|",@$files)."'"
    push @cmd,(
        '-safe',0
        ,'-f','concat'
        ,'-i',$file_inputs
#        ,'-c:v','copy'
        ,'-c:a','aac'
        ,'-shortest'
        ,'-strict',-2
        ,@ENCODER
        ,'-y',$file_out);
    my ($in, $out, $err);
    print join(" ",@cmd)."\n"        if $DEBUG;
    print("Joining videos\n")       if $VERBOSE;
    run3(\@cmd, \$in, \$out, \$err);
    die $err if $?;

#avconv -i concat:"file1.ts|file2.ts|file3.ts" -c copy \
#   -bsf:a aac_adtstoasc
}

sub video_size {
    my $file = shift;
    my @cmd = ('ffmpeg','-i', $file);
    my ($in, $out, $err);
    run3(\@cmd, \$in, \$out, \$err);
    chomp $err if $err;
    die join(" ",@cmd)." : $?\n".$err if $? && $? != 256;

    my ($w,$h) = $err =~ /Stream.*?Video.*?(\d+\d)x(\d+\d)/m;
    die "I can't find size in $err" if !$h;
    die "I can't find size in $err" if !$w;

    return($w,$h);
}

sub calculate_height {
    my $video_in = shift;
    my ($w, $h) = video_size($video_in);
    my $h2 = $WIDTH * $h /$w;
    $h2-- if $h2 % 2;
    return $h2;
}
sub create_slideshow {
    my $images = shift;
    my $video = $images->[0];
    $video =~ s{(.*/).*?(\d+)\.\w+}{$1vid$2.ts};
    confess "No file in images->[0] ".Dumper($images) if !$video;
    return $video if -e $video && -s $video;
    my ($pattern,$ext) = $images->[0] =~ m{(.*)\d{4}\.(.*)};
    die "I can't find pattern in $images->[0] ".Dumper($images) if !$pattern;

    # avconv -ss 0 -i input.mp4 -t 60 -vcodec libx264 -acodec aac \
#    -bsf:v h264_mp4toannexb -f mpegts -strict experimental -y file1.ts
    my @cmd = ('ffmpeg'
                ,'-f','image2'
                ,'-r',$FRAME_RATE
                ,'-i',"$pattern\%04d.$ext"
                ,'-f','mpegts'
                ,@ENCODER
            );
    push @cmd, ('-b:v','1000k','-an','-y',$video);
    print("Creating slideshow $video\n")    if $VERBOSE;
    print join(" ",@cmd)."\n"               if $DEBUG;
    my ($in, $out, $err);
    run3(\@cmd, \$in, \$out, \$err);
    die $err if $?;

    return $video;
}

sub convert_scale {
    my ($file_in, $file_out, $width) = @_;
    return if -e $file_out && -s $file_out;
    my @cmd = ('convert','-depth', $DEPTH,'-scale',$width, $file_in
            , "png24:$file_out");
    my ($in, $out, $err);

    print("scaling to $file_out\n")     if $VERBOSE>1;
    print join(" ",@cmd)."\n"           if $DEBUG;
    run3(\@cmd, \$in, \$out, \$err);
    die $err if $?;
}

sub convert_crop {
    my ($file_in, $file_out, $geo, $label) = @_;
    return if -e $file_out && -s $file_out;
    my @cmd = ('convert', '-depth', $DEPTH
            , '-page',$geo
            , $file_in
            , '-crop',$geo
    );
    push @cmd,('-fill', $FONT_COLOR, '-gravity','center', '-pointsize', int($HEIGHT/6),'-annotate','-0+0',$label)
        if $label && $INFO;
    push @cmd,( "png24:$file_out");
    my ($in, $out, $err);

    print("cropping to $geo $file_out\n")    if $VERBOSE>1;
    print join(" ",@cmd)."\n"           if $DEBUG;
    run3(\@cmd, \$in, \$out, \$err);
    die $err if $?;

}


sub zoomin_image {
    my ($file_in, $file_out, $offset) = @_;

    # 1. scale to size
    my ($name) = $file_in =~ m{.*/(.*)\.\w+};
    my $file_scaled = "$DIR_TMP/work/$name.sc.$WIDTH.png";
    convert_scale($file_in,$file_scaled,$WIDTH);

    # 2. crop to size-offset
    my $geo = ($WIDTH - $offset*2)."x".($HEIGHT - $offset)
        ."+".($offset*2)."+$offset";
    my $width = $WIDTH - $offset*2;
    my $height = $HEIGHT - $offset;
    my $file_cropped = "$DIR_TMP/work/$name.cr.$offset.png";
    convert_crop($file_scaled, $file_cropped, $geo);

    # 3. scale to width
    my $file_scaled2 = "$DIR_TMP/work/$name.sc2.$offset.$WIDTH.png";
    convert_scale($file_cropped, $file_scaled2, $WIDTH);

    # 4. crop to width height
    my ($label) = $file_in =~ m{.*/(.*)};
    $label = $file_in if !$label;
    convert_crop($file_scaled2, $file_out, "${WIDTH}x$HEIGHT+0+0!", $label);

}

sub fit_img_pp {
    my ($file_in, $file_out, $offset, $brightness, $label) = @_;
    $offset = 0 if !$offset;

    confess "Offset negatiu" if $offset<0;

    my ($name) = $file_in =~ m{.*/(.*)\.\w+};
    confess "No name found in $file_in" if !$name;
    my $file_scaled = "$DIR_TMP/$name.png";

    my $width = $WIDTH;
    $width = $width + $FRAME_RATE * 4 if defined $offset;
    my $in = Image::Magick->new();
    my $err = $in->Read($file_in);
    confess $err if $err;

    print(" > Scaling $width $file_in\n")     if $VERBOSE>1;
    $err = $in->Scale(geometry => ${width});
    confess $err if $err;

    if ( $offset || $brightness || $label) { # crop
        my $size = "${WIDTH}x${HEIGHT}+$offset+$offset";
        my $msg = "cropping $file_in -> $size $file_out";

        $msg .= " -brightness $brightness" if $brightness;
        print "$msg\n"  if $VERBOSE>1 || $DEBUG;

        $in->Crop( geometry => $size );
#        $in->Level( level => (100-$brightness));
        $in->Modulate( brightness => $brightness ) if $brightness;
    }
    
    my $resize_x = $WIDTH;
    my $resize_y = $HEIGHT;

    $resize_y++ if $resize_y % 2;

    $in->Modulate( brightness => $brightness ) if defined $brightness;
    $in->Resize( geometry => "${resize_x}x${resize_y}!" );
#    warn "resize ${resize_x}x${resize_y}\n" if $DEBUG;
    
=pod

    TODO annotate image

    push @cmd,('-fill', 'black', '-gravity','center', '-pointsize', int($HEIGHT/6)
                    ,'-annotate','-0+0',$label)
            if $label && $INFO;
        # label ?

=cut

#    $in->Set (depth => 8);
#    $in->Set(type => 'TrueColor');
#    $in->Normalize( channel => 'RGB' );
    $in->Write("png24:$file_out");
}

sub fit_img_run {
    my ($file_in, $file_out, $offset, $brightness, $label) = @_;
    $offset = 0 if !$offset;
#convert -scale 800 IMG_934$i.JPG a.png ; convert a.png -crop 800x532+0+0 input$i.png
    my ($name) = $file_in =~ m{.*/(.*)\.\w+};
    confess "No name found in $file_in" if !$name;
    my $file_scaled = "$DIR_TMP/$name.png";

    if (! -e $file_scaled || ! -s $file_scaled ) {
        my $width = $WIDTH;
        $width = $width + $FRAME_RATE * 4 if defined $offset;
        my @cmd = ('convert','-depth', $DEPTH,'-scale',$width, $file_in
            , "png24:$file_scaled");
        my ($in, $out, $err);

        print("Scaling $file_in\n")     if $VERBOSE>1;
        print join(" ",@cmd)."\n"           if $DEBUG;
        run3(\@cmd, \$in, \$out, \$err);
        die $err if $?;
    }

    my ($x, $y) = imgsize($file_scaled);
    my ($x2, $y2) = ($x, $y);
    $x2 = $x-1 if $x % 2;
    $y2 = $y-1 if $y % 2;
    if ( $y2 != $HEIGHT || $x2 != $WIDTH || $offset || $brightness || $label) { # crop
        $x2 = $x if !$x2;
        $y2 = $y if !$y2;
        my $size = "${WIDTH}x${HEIGHT}+$offset+$offset!";
        my $msg = "cropping $size $file_out";
        $msg .= " -brightness $brightness"  if $brightness;
        print "$msg\n"  if $VERBOSE>1;
        my @cmd = ( 'convert');
        
        push @cmd,( $file_scaled,'-crop',$size
            ,'-depth', $DEPTH);
        push @cmd,('-fill', 'black', '-gravity','center', '-pointsize', int($HEIGHT/6)
                    ,'-annotate','-0+0',$label)
            if $label && $INFO;
        # label ?
        push @cmd,('-brightness-contrast',$brightness)   if $brightness;
        push @cmd,("png24:$file_out");
        my ($in, $out, $err);
        run3(\@cmd, \$in, \$out, \$err);
        die $err if $?;
    } else {
        copy($file_scaled, $file_out);
    }
}

sub fit_img {
    return fit_img_pp(@_);
}

sub tmp_n {
    my $n = shift;

    my $count = $COUNT{$n}++;
    while (length($count) < 4) { $count = "0".$count }

    return $count;
}

sub tmp_file {
    my $n = shift;
    my $ext = shift or confess "I need the extension";

    my $out = "img".tmp_n($n);

    mkdir "$DIR_TMP/$n" or die "$! $DIR_TMP/$n"
        if ! -e "$DIR_TMP/$n";

    return "$DIR_TMP/$n/$out.$ext";
}

sub scale_images_0 {
    my $images = shift;
    my $n = shift;
    die "Missing group number"  if !defined $n;

    my @scaled;
    for my $file ( @$images ) {
        my $out = tmp_file($n,'png');
        fit_img($file,$out)
            if ! -e $out || ! -s $out;
        push @scaled,($out);
    }
    return \@scaled;
}

sub effect_zoomin {
    my $image = shift;
    my $n = shift;

    my @scaled;
    print "Zoom in $image\n"    if $VERBOSE;
    my $offset = 0;
    for ( 0 .. $FRAME_RATE ) {
        print "." if $VERBOSE == 1;
        my $out = tmp_file($n,'png' );
        zoomin_image($image, $out, $offset);
        $offset++;
        push @scaled,($out);
    }
    for ( 0 .. $FRAME_RATE/2 ) {
        print "." if $VERBOSE == 1;
        my $out = tmp_file($n,'png' );
        zoomin_image($image, $out, int $offset);
        $offset += 0.5;
        push @scaled,($out);
    }

    print "\n"  if $VERBOSE == 1;
    return @scaled;
}

sub fadein_image {
    my $image = shift;
    my $n = shift;
    my $long = shift;
    die "Missing group number"  if !defined $n;

    print "Fade in $image\n" if $VERBOSE;

    my ($label) = $image =~ m{.*/(.*)};
    $label = $image if !$label;

    my $r = $FRAME_RATE;
    my $r0;
    $r0 = $r/2;
    $r0 = 0     if $long;

    my @scaled;
    my $offset = $r-$r0;
    for my $n2 ($r0 .. $r ) {
            my $out = tmp_file($n,'png' );
            my $brightness = 100 - int (( $r - $n2 )/2/$r*100);
            print "."       if $VERBOSE== 1;
            fit_img($image, $out, $offset, $brightness, $label)
                    if ! -e $out || ! -s $out;
            push @scaled,($out);
            $offset-- if $offset>0;
    }
    $r0 = $r/2;
    $r0 = 0 if $long;
    $r+= $FRAME_RATE if $long;
    $r+= $FRAME_RATE*2 if $long && $SLOW_PICS;

    for my $n2 ( $r0+1 .. $r+2 ){
            my $out = tmp_file($n,'png' );
            print "."       if $VERBOSE== 1;
            fit_img($image, $out, int $offset, undef , $label)
                    if ! -e $out || ! -s $out;
            push @scaled,($out);
            $offset -= 0.5 if $offset>0;
    }
    print "\n";
    return @scaled;
}
sub fadein_image_slow {
    return fadein_image(@_, 1);
}

sub random_effect_image {
    return effect_zoomin(@_);
}

sub scale_images {
    my $images = shift;
    my $n = shift;

    my @scaled;

    push @scaled,fadein_image_slow($images->[0], $n);
    for my $index (1 .. $#$images) {
        push @scaled,random_effect_image($images->[$index], $n);
    }
    return \@scaled;
}

sub is_video {
    my $file = shift;
    my ($ext) = $file =~ m{\.(\w+)$};
    return if !$ext;
    return $EXT_VIDEO{lc($ext)};
}

sub group_files {
    my $files = shift;
    my @groups;
    my @images;

    for my $file ( sort { $files->{$a}->{date} cmp $files->{$b}->{date} } keys %$files ) {
        if (is_video($file)) {
            my @images2 = @images;
            push @groups,(\@images2) if scalar @images;
            push @groups,($file);
            @images = ();
            next;
        }
        push @images,($file);
    }
    push @groups,(\@images)  if scalar @images;
    return \@groups;
}

sub build_slideshows {
    my $groups = shift;
    my $n = 0;
    my $video;
    my $last_image = search_last_image($groups);
    for my $item (@$groups) {
        if (ref($item)) {
            next if !$item->[0];
            my $images = scale_images($item, $n);
            $video = create_slideshow($images);
        } else {
            $video = convert_ts($item, $n);
        }
#        print "$video\n";
        $item = $video;
        $n++;
    }
    return if !$last_image;
    push @$groups,fadeout_image_slow($last_image,$n);
}

sub fadeout_image {
    my $file = shift;
    my $n = shift;

    my $r = $FRAME_RATE;
    my @scaled;

    for my $n2 ( 0 .. $r ) {
        my $out = tmp_file($n,'png' );
        my $brightness = int ( $n2 /$r*100);
        fit_img($file, $out, $n2, -$brightness)
                    if ! -e $out || ! -s $out;
        push @scaled,($out);
   }
   return create_slideshow(\@scaled, $r);
}

sub fadeout_image_slow {
    my $file = shift;
    my $n = shift;

    my $r = $FRAME_RATE;
    my @scaled;

    $r += $FRAME_RATE*2 if $SLOW_PICS;
    for ( 0 .. $r ) {
        my $out = tmp_file($n,'png' );
        fit_img($file, $out)
                    if ! -e $out || ! -s $out;
        push @scaled,($out);
    }

    for my $n2 ( 0 .. $r ) {
        my $out = tmp_file($n,'png' );
        my $brightness = 100 - int ( $n2 /$r*100);
        fit_img($file, $out, $n2, $brightness)
                    if ! -e $out || ! -s $out;
        push @scaled,($out);
   }
   return create_slideshow(\@scaled, $r);
}


sub search_last_image {
    my $groups = shift;
    my $last_image;

    for my $item (reverse @$groups) {
        next if !ref($item);
        $last_image = $item->[-1];
        $#{$item}--;
        $item = undef if !$#$item;
        last;
    }
    return $last_image;
}

sub remove_empty_groups {
    my $groups = shift;

    my $changes = 0;
    my @groups2;
    for my $item (@$groups) {
        if (!defined $item || ( ref $item && !defined $item->[0]) ) {
            $changes++;
            next;
        }
        push @groups2,($item);
    }
    return if !$changes;

    @$groups = @groups2;

}

sub set_tmp_dir {
    my $groups = shift;

    for my $item (@$groups) {
        if (ref($item)) {
            my ($name) = $item->[0] =~ m{.*/(.*)\..*};
            next if !$name;
            $DIR_TMP .= "/$name";
            last if $name;
        }
    }
    mkdir $DIR_TMP          or die $! if ! -e $DIR_TMP;
    mkdir "$DIR_TMP/work"   or die $! if ! -e "$DIR_TMP/work";
}

sub split_list {
    my $list = shift;
    my @list1 = @$list;
    $#list1 /= 2;

    my @list2;
    for ( $#list1+1 .. $#$list ) {
        push @list2,($list->[$_]);
    }
    return (\@list1, \@list2);
}

sub tidy_groups {
    my $group = shift;
    my $groups2;
    push @$groups2,( $group->[0] );
    push @$groups2,( $group->[1] );
    my $n2 = 2;
    for my $n (2 .. $#$group) {
        if (!ref $group->[$n] && !ref $group->[$n-1] && ref $group->[$n-2]
            && scalar($group->[$n-2])>3
        ) {
            my ($tidy0,$tidy1) = split_list($groups2->[$n2-2]);
            $groups2->[$n2-2] = $tidy0;
            push @$groups2,($tidy1);
            $n2++;
        }
        push @$groups2,($group->[$n]);
        $n2++;
    }
    $groups2 = tidy_groups($groups2) if scalar @$groups2 > scalar @$group;
    return $groups2;
}

sub init_encoder {
    my @cmd = ( 'ffmpeg','-encoders');
    my ($in, $out, $err);

    run3(\@cmd, \$in, \$out, \$err);
    for my $line (split /\n/,$out) {
        my ($encoder) = $line =~ /\s+V.{5} (\w\w+) /;
        next if !$encoder;
        if ($encoder =~ /264/) {
            @ENCODER = ('-c:v',$encoder);
            last;
        } elsif ($encoder =~ /263p/) {
            @ENCODER = ('-c:v',$encoder);
        }
    }
}

sub init_format {
    my @cmd = ( 'ffmpeg','-pix_fmts');
    my ($in, $out, $err);

    my %format;
    run3(\@cmd, \$in, \$out, \$err);
    for my $line (split /\n/,$out) {
        my ($found) = $line =~ /.O.*? (\w\w+) /;
        next if !$found;
        $format{$found}++;
    }
    for (@PREFERRED_FORMATS) {
        next if !$format{$_};
        push @ENCODER,('-pix_fmt',$_);
        last;
    }
}

sub init_drawtext {
    return if !$INFO;

    my @cmd = ( 'ffmpeg','-filters');
    my ($in, $out, $err);

    run3(\@cmd, \$in, \$out, \$err);
    for my $line (split /\n/,$out) {
        my ($filter) = $line =~ /\s+T.*? (\w\w+) /;
        next if !$filter;
        if ($filter=~ /drawtext/) {
            $DRAWTEXT = $filter;
            last;
        }
    }
    if (!$DRAWTEXT && $INFO) {
        die "ffmpeg drawtext filter not available, compile it with libfreetype\n";
    }

}

sub init {
    mkdir $DIR_TMP if ! -e $DIR_TMP;
    init_encoder();
    init_format();
    init_drawtext();
}

sub move_last_image {
    my $groups = shift;
    my $last_image = search_last_image($groups);
    push @$groups,[ $last_image ];
    remove_empty_groups($groups);

}
#################################################

init();

my $dir = ($ARGV[0] or '.');
$dir =~ s{/$}{};

my $out = "$dir.mp4";
$out =~ s{.*/}{};
my $files = list_files($dir);

show_dates($files) if $SHOW_DATES;

my $groups = group_files($files);
move_last_image($groups);
$groups = tidy_groups($groups) if $TIDY;
die Dumper($groups) if $SHOW_GROUPS;

set_tmp_dir($groups);
build_slideshows($groups);
join_videos($groups, $out);
