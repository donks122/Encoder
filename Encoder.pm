#! /usr/bin/perl -w 

use strict;
package Encoder;

use POSIX ();
use DBI;
use File::Path;
use IPC::Open3;
eval {require './modules/Encoder.conf';};
eval {require './modules/Ffmpeg_map.conf';};
eval {require './modules/eyed3_map.conf';};
eval {require 'start.conf';};


sub new {
    my $self = bless { };
    return $self;
}


sub encode {
    my ($self,$media_info) = @_;

    my ($err_flg,$flag) = (0,0);

    my $encode_category = $media_info->{'media_type'};

    my $source = $media_info->{source};

    if (!$source) {
      warn " Unable to Find file for $media_info->{'id'}";
      return;
    }


    my ($directory,$file) = $source  =~ /(.*\/)(.*)$/;

    system("cp $source /tmp/ffmpeg/$file");

    $self->{has_cache} = 0;

    foreach my $profile (keys %{$self->{$encode_category}}){

        my $preview_type = '';

        my $target = "$file".'_'."$profile".".$self->{$encode_category}->{$profile}->{defaultFileExtension}";

        my $options = $self->getOptions($self->{$encode_category}->{$profile});

        if ($profile =~ /preview/){
          my ($clip_start,$clip_length);
          ($clip_start,$clip_length,$flag,$preview_type) = $self->getClipDetails($media_info->{'id'});
          $options .= ' -ss ' . $clip_start . ' -t ' . $clip_length if (($flag > 0) && ($preview_type ne 'full'));
        }
        my $pass = '';
        if ($encode_category eq 'video'){
         my $up_flag = $self->get_image($media_info->{'id'}); 
         $self->create_image($file,$up_flag,$media_info->{'id'}) ;
	 if ($self->{$encode_category}->{$profile}->{videoEncodePass} == 2){
            my $pass_file = 'twoPassLogFile.'.time.'.ffmpeg.log';
            $options .= ' -passlogfile ' . '/tmp/ffmpeg/' . $pass_file;
          }

          my $aspect = $self->get_aspect_ratio($file);
          my $size = $self->video_size_from_aspect_ratio($aspect,$self->{$encode_category}->{$profile}->{videoSize});
          $options .= ' -aspect ' . $aspect . ' -s ' . $size . ' -sameq -pass ';         
          $pass = 1;
        }

        my $ffmpeg_cmd = "$self->{ffmpeg} -i /tmp/ffmpeg/$file $options  $pass /tmp/ffmpeg/$target";

        eval { warn "Execute:[$ffmpeg_cmd]\n";
               my $log = `$ffmpeg_cmd`; 
               warn $log if $self->{debug};
               warn "Done:[$ffmpeg_cmd]\n";
             };
          die "Encode Failed with :[$@]" if $@;

        if ($profile =~ /bitrate192|bitrate320/) {
            $self->{tag_opts} = $self->tag_mp3($file,$media_info) if ($self->{has_cache} == 0);
            my $eyed3_cmd = $self->{eyed3_home} . ' ' . $self->{tag_opts} . ' /tmp/ffmpeg/' . $target;
            my $eyed3_convert = $self->{eyed3_home} . ' --to-v2.3 /tmp/ffmpeg/'  . $target; 
            eval { warn "Execute:[$eyed3_cmd]\n";
                   `$eyed3_cmd`;
                   warn "Done:[$eyed3_cmd]\n";

                   warn "Execute:[$eyed3_convert]\n";
                   `$eyed3_convert`;
                   warn "Done:[$eyed3_convert]\n";
                 };
        }

        my $contentid = '';
        if ($profile =~ /web_flash_preview/){
            my $fast_target = $self->exec_faststart($target);
            $contentid = $self->put_into_hstore("/tmp/ffmpeg/$fast_target");
            unlink("/tmp/ffmpeg/$fast_target") || warn "Unable to remove TEMPFILE: /tmp/ffmpeg/$fast_target\n";
        } elsif (($profile =~ /mp3_preview/) && ($preview_type ne 'full')) {
            my $fade_target = $self->add_fade_to($target,$flag);
            $contentid = $self->put_into_hstore("/tmp/ffmpeg/$fade_target");
            unlink("/tmp/ffmpeg/$fade_target") || warn "Unable to remove TEMPFILE: /tmp/ffmpeg/$fade_target\n";
        } elsif ($self->{$encode_category}->{$profile}->{videoEncodePass} == 2 && $profile !~ /web_flash_preview/) {
           $pass = 2;
           my $ffmpeg_cmd = "$self->{ffmpeg} -i /tmp/ffmpeg/$target $options $pass -y /tmp/ffmpeg/$target" .'pass.mp4';  
           eval { warn "Execute:[$ffmpeg_cmd] Pass 2\n";
               my $log = `$ffmpeg_cmd`;
               warn $log if $self->{debug};
               warn "Done:[$ffmpeg_cmd] Pass 2\n";
             };
             die "Encode Failed with :[$@]" if $@;

           unlink("/tmp/ffmpeg/$pass_file") || warn "Unable to remove PASSFILE: /tmp/ffmpeg/$pass_file";

           $contentid = $self->put_into_hstore("/tmp/ffmpeg/$target".'pass.mp4');
           unlink("/tmp/ffmpeg/$target" .'pass.mp4') || warn "Unable to remove TEMPFILE: /tmp/ffmpeg/$target.pass.mp4";
        } else {
           $contentid = $self->put_into_hstore("/tmp/ffmpeg/$target");
        } 

        unlink("/tmp/ffmpeg/$target") || warn "Unable to remove TEMPFILE: /tmp/ffmpeg/$target\n";
        $self->insert_new_media($media_info,$profile,$contentid);
    
    }

    unlink("/tmp/ffmpeg/$file") || warn "Unable to remove TEMPFILE: /tmp/ffmpeg/$file\n";

    $self->update_media_status($media_info->{'id'},'active');

    return 1;
}

sub tag_mp3 {
  my ($self,$file,$media_info) = @_;
  my $opt = '';
  my $hash = {};
  local $| = 1;
  my($wtr, $rdr, $err);
  my $cmd = $self->{eyed3_home}. ' -v /tmp/ffmpeg/' . $file;
  $pid = open3($wtr, $rdr, $err, "$cmd");
  while (my $line = <$rdr> ){
    next if ($line !~ /^\</);
    my ($key,$value) = ($line =~ /\((.{4,4})\):(.*)\>/);
    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    $hash->{$key} = $value;
  }
  warn $pid;

  $mp3_frames_map = {  'APIC' => 'thumbnail', 
                       'TALB' => 'album', 
                       'TCOM' => 'composer', 
                       'TIT2' => 'title', 
                       'TPE1' => 'artist', 
                       'TPUB' => 'publisher', 
                       'TSRC' => 'isrc', 
                       'TYER' => 'year', 
                       'TCON' => 'genre', 
                       'UFID' => 'ufid', 
                     };

   foreach my $keys (keys %{$self->{eyed3}}){
     next if ($hash->{$keys} && length($hash->{$keys}) > 1);
     $hash->{$keys} = $self->get_attrib($mp3_frames_map->{$keys},$media_info);
     delete($hash->{$keys}) if (!$hash->{$keys});
   } 

   foreach my $key (keys %$hash){
     my $concat = '=' if ($self->{eyed3}->{$key}->{cmd} !~ /\-\-set\-text\-frame/); 
     my $quoted_value = $dbh->quote($hash->{$key});
     $opt .= ' ' . $self->{eyed3}->{$key}->{cmd} . $concat . $quoted_value if ($self->{eyed3}->{$key}->{cmd});
   }

   $self->{has_cache} = 1;

   return $opt;
}

sub create_image {
  my ($self,$data,$update_flag,$media_id) = @_;
  return if ($update_flag == 1);
  my $command = "$self->{ffmpeg} -i /tmp/ffmpeg/$data  -f image2 -vcodec mjpeg -ss 00:00:30.000 -t 00:00:00.001 /tmp/ffmpeg/$data.jpg";
  my $log = `$command`;
  warn $log if $self->{debug};
  my $contentid = $self->put_into_hstore("/tmp/ffmpeg/$data.jpg");
warn "CONTENT: $contentid\n";
  unlink("/tmp/ffmpeg/$data.jpg") || warn "Unable to remove TEMPFILE: /tmp/ffmpeg/$data.jpg";
  return 1;
}

sub get_image {
  my ($self, $mediaid) = @_;
  my ($result); # image path;
 warn "THUMBNAIL: $result\n";
  return 0 if !$result;
  return 1 if ( -e $self->getpath($result));
  return 2;
}


sub getClipDetails {
  my ($self,$mediaid) = @_;
  my ($start,$length,$type);
  foreach my $row (@$clip_details){
    $start = $row->[0] if ($row->[1] eq 'preview_start');
    $length = $row->[0] if ($row->[1] eq 'preview_length');
    $type = $row->[0] if ($row->[1] eq 'preview_type');
  }
  
  $start = 10 if ($start < 1);
  $length =30 if ($length < 1); 

  my $nstart = $self->timeformat($start);
  my $nlength = $self->timeformat($length);
  return ($nstart,$nlength,$length,$type);
}

sub timeformat {
  my ($self,$time) = @_;
  my $s = $time%60;
  my $m=(($time%3600)-$s)/60;
  my $h=$s/3600;
  $h=~s/^(\d+).*/$1/;
  $newtime = "$h:$m:$s";
  return ($newtime);
}


sub exec_faststart {
    my ( $self, $input ) = @_;
    my $output = $input . '.fast';
    my $cmd = $self->{'faststart'} . ' ' . join(' ', "/tmp/ffmpeg/$input", "/tmp/ffmpeg/$output");
    my $log = `$cmd`;
    warn $log if $self->{debug};
    return $output;
}

sub add_fade_to {
    my ( $self, $input, $duration  ) = @_;
    my $output = $input . '_fade.mp3';
    my $cmd = $self->{'fade'} . ' -v 0.95 ' . join(' ', "/tmp/ffmpeg/$input", "/tmp/ffmpeg/$output");
    $cmd .= " fade p 1 $duration 2";
    my $log = `$cmd`;
    warn $log if $self->{debug};
    return $output;
}

sub get_aspect_ratio {
    my ( $self, $input ) = @_;
    my $output = $input .'.aspect';
    my $cmd = $self->{'ffmpeg'} . ' -i ' . "/tmp/ffmpeg/$input" . " 2>/tmp/ffmpeg/$output";
    my $log = `$cmd`;
    warn $log if $self->{debug};
    open($fh, "/tmp/ffmpeg/$output") or die "Error $@";
    my ($video_info) = grep { /Video:/i } <$fh>;
    $video_info =~ m/(\d+)x(\d+)/;
    my ($width, $height) = ($1, $2);
    close($fh);
    unlink("/tmp/ffmpeg/$output");
    return ($width/$height) ? ($width/$height) : 1;
}

sub video_size_from_aspect_ratio {
    my ( $self, $aspect,$video_size ) = @_;
    $video_size =~ m/(\d+)x\d+/;
    my $height = int($1/$aspect);
    return "$1x" . ( $height - $height % 2 );
}



sub getOptions{
  my ($self,$profile) = @_;
  my $opt = '';
  my $partitions = '';
  foreach my $key (keys %$profile){
    next if (($key eq 'videoSize') || ($key eq 'videoEncodePass'));
    if($key eq 'loop'){
      $opt .= ' -flags' . ' +' . $key;
      next;
    }
    if($key =~ /partp|parti/ ) {
      $partitions .= '+' . $key;
      next;
    }
    if($key eq 'chroma'){
      $opt .= ' -cmp' . ' +' . $key;
      next;
    }
    $opt .= ' -' . $self->{cmd_map}->{$key}->{cmd} . ' ' . $profile->{$key} if ($self->{cmd_map}->{$key}->{cmd});
  }
  $opt .= ' -partitions ' . $partitions if (length($partitions) > 1);

  return $opt;
}

sub get_attrib {
  my ($self,$attrib,$media_info) = @_;
  
  if ($attrib eq 'ufid') {
    my $str = '0:' . $media_info->{'id'};
    return $str;
  }
  return $media_info->{'name'} if ($attrib eq 'title');

  if ($attrib eq 'thumbnail'){
    my $path = $self->{hstore}->getpath($result);
    my $image = 0;
    if ( -e $path ){
      my $tmp_file = $result . ".jpg";
      my $image_cmd = 'convert ' . $path . ' -colorspace RGB -resize 250x250 /tmp/ffmpeg/' . $tmp_file;
      eval{`$image_cmd`;};
      if(!(-e "/tmp/ffmpeg/$tmp_file")){
        system("cp $path /tmp/ffmpeg/$tmp_file");
      }
      $image = '/tmp/ffmpeg/' . $tmp_file .':FRONT_COVER';
      $self->{image_path_tag} = "/tmp/ffmpeg/$tmp_file";
      if (!(-e "/tmp/ffmpeg/$tmp_file")) {
        $image = '';
        $self->{image_path_tag} = '';
      }
    }
    $result = $image;
  }

  return $result;
}

sub get_media_info {
    my ($self,$id) = @_;

    my $media_info = {};

    $media_info->{'id'} = $id;
    $media_info->{'contentid'} = $info[0][0];
    $media_info->{'media_type'} = $self->{media_map}->{$info[0][1]};
    $media_info->{'name'} = $info[0][2];
    
    return $media_info;

}


=pod

=head1 AUTHOR

Sandeep Nyamati( sandeep.nyamati@gmail.com ) 

=cut

1;
