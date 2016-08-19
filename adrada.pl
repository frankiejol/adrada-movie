#!/usr/bin/perl

use warnings;
use strict;

use Carp qw(confess);
use Data::Dumper;
use Getopt::Long;
use Image::Size;
use IPC::Run3 qw(run3);

my $WIDTH = 800;
my $HEIGHT = 450 ;

my $DIR_TMP = "/var/tmp/img";
my $VIDEO_DURATION = 10;
my $AUDIO_FILE;
my $FRAME_RATE = 24;
my $FPS_SLOW = 18;
my $SLOW;
my $TIDY;
my $HELP;

GetOptions(
     'audio=s' => \$AUDIO_FILE
    ,'width=s' => \$WIDTH
    ,'fps-slow=s' => \$FPS_SLOW
    ,'video-duration=s' => \$VIDEO_DURATION
        ,slow  => \$SLOW
        ,tidy  => \$TIDY
        ,help  => \$HELP
) or exit;

die "Missing audio file '$AUDIO_FILE"
    if $AUDIO_FILE && !-e $AUDIO_FILE;# || !stat($AUDIO_FILE);

if ($HELP) {
    my ($me) = $0 =~ m{.*/(.*)};
    print "$me [--help] [--width=$WIDTH] [--slow] [--tidy]"
        ." [--audio=file]"
        ."\n"
        ."\t--width : output width, height is scaled in 1200x720\n"
        ."\t--slow : videos are played in slow motion at 'fps-slow' fps\n"
        ."\t--fps-slow : frames per second when slow motion, defaults "
            ."to $FPS_SLOW\n"
        ."\t--tidy : tries to group videos and pictures\n"
        ."\t--video-duration : trims videos to this duration, defaults "
            ."to $VIDEO_DURATION\n"
        ."\t--audio: add this audio file to the final video\n"
    ;
    exit;
}
$HEIGHT = int($WIDTH * 720 /1200);

my %EXT_IMG = map { lc($_) => 1 } qw( jpg png gif );
my %EXT_VIDEO = map { lc($_) => 1 } qw( mov 3gp mp4 ts avi);

my %COUNT;
my @ENCODER;

##############################################
sub list_files {
    my $dir = shift;

    opendir my $ls,$dir or die "$! $dir";

    my %pic;
    while ( my $file = readdir $ls) {
        $file = "$dir/$file";
        my ($ext) = $file =~ m{.*\.(\w+)$};
        next if !$ext;
        next if !$EXT_IMG{lc($ext)}
            && !$EXT_VIDEO{lc($ext)};
        next if ! -f $file;
        my @stat = stat($file) or die "I can't stat $file";
        $pic{$file} = { date => $stat[9]};
    }
    return \%pic;
}

sub convert_ts {
    my $video_in = shift;
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
    push @cmd,('-t',$VIDEO_DURATION)    if $VIDEO_DURATION;
    push @cmd,('-an')                   if $SLOW;
    push @cmd,(
        '-y'
        ,$video_out
    );
    my ($in, $out, $err);
    print("Converting $video_in to ts\n");
    warn join(" ",@cmd)."\n";
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
    warn join(" ",@cmd)."\n";
    print("Joining videos\n");
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
    warn join(" ",@cmd)."\n";
    my ($in, $out, $err);
    print("creating $video\n");
    run3(\@cmd, \$in, \$out, \$err);
    die $err if $?;

    return $video;
}

sub convert_scale {
    my ($file_in, $file_out, $width) = @_;
    return if -e $file_out && -s $file_out;
    my @cmd = ('convert','-depth', 24,'-scale',$width, $file_in
            , "png24:$file_out");
    my ($in, $out, $err);

    print("scaling to $file_out\n");
    warn join(" ",@cmd)."\n";
    run3(\@cmd, \$in, \$out, \$err);
    die $err if $?;
}

sub convert_crop {
    my ($file_in, $file_out, $geo) = @_;
    return if -e $file_out && -s $file_out;
    my @cmd = ('convert', '-depth', 24
            , '-page',$geo
            , $file_in
            , '-crop',$geo
            , "png24:$file_out");
    my ($in, $out, $err);

    print("cropping to $file_out\n");
    warn join(" ",@cmd)."\n";
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
    convert_crop($file_scaled2, $file_out, "${WIDTH}x$HEIGHT+0+0");

}

sub fit_img {
    my ($file_in, $file_out, $offset, $brightness) = @_;
    $offset = 0 if !$offset;
#convert -scale 800 IMG_934$i.JPG a.png ; convert a.png -crop 800x532+0+0 input$i.png
    my ($name) = $file_in =~ m{.*/(.*)\.\w+};
    confess "No name found in $file_in" if !$name;
    my $file_scaled = "$DIR_TMP/$name.png";

    if (! -e $file_scaled || ! -s $file_scaled ) {
        my $width = $WIDTH;
        $width = $width + $FRAME_RATE * 4 if defined $offset;
        my @cmd = ('convert','-depth', 24,'-scale',$width, $file_in
            , "png24:$file_scaled");
        my ($in, $out, $err);

        print("scaling $file_in\n");
        run3(\@cmd, \$in, \$out, \$err);
        die $err if $?;
    }

    my ($x, $y) = imgsize($file_scaled);
    my ($x2, $y2);
    $x2 = $x-1 if $x % 2;
    $y2 = $y-1 if $y % 2;
    if ( $y2 != $HEIGHT || $x2 != $WIDTH || $offset || $brightness) { # crop
        $x2 = $x if !$x2;
        $y2 = $y if !$y2;
        my $size = "${WIDTH}x${HEIGHT}+$offset+$offset";
        my $msg = "cropping $size $file_out";
        $msg .= " -brightness $brightness"  if $brightness;
        print "$msg\n";
        my @cmd = ( 'convert');
        
        push @cmd,( $file_scaled,'-crop',$size
            ,'-depth',24);
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
    for my $offset ( 0 .. $FRAME_RATE ) {
        my $out = tmp_file($n,'png' );
        zoomin_image($image, $out, $offset*2);
        push @scaled,($out);
    }
    return @scaled;
}

sub fadein_image {
    my $image = shift;
    my $n = shift;
    my $long = shift;
    die "Missing group number"  if !defined $n;

    my $r = $FRAME_RATE;
    my $r0;
    $r0 = $r/2;
    $r0 = 0     if $long;

    my @scaled;
    my $offset =0;
    for my $n2 ( $r0 .. $r ) {
            my $out = tmp_file($n,'png' );
            my $brightness = int (( $r - $n2 )/$r*100);
            fit_img($image, $out, $offset, -$brightness)
                    if ! -e $out || ! -s $out;
            push @scaled,($out);
            $offset+=2;
    }
    $r0 = $r/2;
    for my $n2 ( $r0+1 .. $r+2 ){
            my $out = tmp_file($n,'png' );
            fit_img($image, $out, $offset, )
                    if ! -e $out || ! -s $out;
            push @scaled,($out);
            $offset+=2;
        
    }
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

    push @scaled,fadein_image($images->[0], $n);
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

    for my $file ( sort { $files->{$a}->{date} <=> $files->{$b}->{date} } keys %$files ) {
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
    push @$groups,fadeout_image($last_image,$n);
}

sub fadeout_image {
    my $file = shift;
    my $n = shift;

    my $r = $FRAME_RATE;
    my @scaled;
    for my $n2 ( 0 .. $r ) {
        my $out = tmp_file($n,'png' );
        my $brightness = int ( $n2 /$r*100);
        fit_img($file, $out, $n2*2, -$brightness)
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
        if ( ref $item && !defined $item->[0] ) {
            $changes++;
            next;
        }
        push @groups2,($item);
    }
    return if !$changes;

    warn "removed something";
    $groups = [@groups2];

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

sub init {
    mkdir $DIR_TMP if ! -e $DIR_TMP;
    init_encoder();
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
my $files = list_files($dir);

my $groups = group_files($files);
move_last_image($groups);
$groups = tidy_groups($groups) if $TIDY;
set_tmp_dir($groups);
build_slideshows($groups);
join_videos($groups, $out);
