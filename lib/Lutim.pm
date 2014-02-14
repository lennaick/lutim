package Lutim;
use Mojo::Base 'Mojolicious';
use LutimModel;
use MIME::Types 'by_suffix';
use Mojo::Util qw(quote);
use Mojo::JSON;;
use Digest::file qw(digest_file_hex);

# This method will run once at server start
sub startup {
    my $self = shift;

    $self->plugin('I18N');

    my $config = $self->plugin('Config');

    # Default values
    $config->{provisionning} = 100 unless (defined($config->{provisionning}));
    $config->{provis_step}   = 5   unless (defined($config->{provis_step}));
    $config->{length}        = 8   unless (defined($config->{length}));

    $self->secrets($config->{secrets});

    $self->helper(
        render_file => sub {
            my $c = shift;
            my ($filename, $path, $mediatype, $dl) = @_;

            $filename = quote($filename);

            my $asset;
            unless ( -f $path && -r _ ) {
                $c->app->log->error("Cannot read file [$path]. error [$!]");
                $c->flash(
                    msg => $c->l('image_not_found')
                );
                return 500;
            }
            $asset      = Mojo::Asset::File->new(path => $path);
            my $headers = Mojo::Headers->new();
            $headers->add('Content-Type'        => $mediatype.';name='.$filename);
            $headers->add('Content-Disposition' => $dl.';filename='.$filename);
            $headers->add('Content-Length'      => $asset->size);
            $c->res->content->headers($headers);
            $c->res->content->asset($asset);
            return $c->rendered(200);
        }
    );

    $self->helper(
        provisionning => sub {
            my $c = shift;

            # Create some short patterns for provisionning
            if (LutimModel::Lutim->count('WHERE path IS NULL') < $c->config->{provisionning}) {
                for (my $i = 0; $i < $c->config->{provis_step}; $i++) {
                    if (LutimModel->begin) {
                        my $short;
                        do {
                            $short= $c->shortener($c->config->{length});
                        } while (LutimModel::Lutim->count('WHERE short = ?', $short));

                        LutimModel::Lutim->create(
                            short                => $short,
                            counter              => 0,
                            enabled              => 1,
                            delete_at_first_view => 0,
                            delete_at_day        => 0
                        );
                        LutimModel->commit;
                    }
                }
            }
        }
    );

    $self->helper(
        shortener => sub {
            my $c      = shift;
            my $length = shift;

            my @chars  = ('a'..'z','A'..'Z','0'..'9');
            my $result = '';
            foreach (1..$length) {
                $result .= $chars[rand scalar(@chars)];
            }
            return $result;
        }
    );

    $self->defaults(layout => 'default');

    $self->provisionning();

    # Router
    my $r = $self->routes;

    $r->get('/' => sub {
            my $c = shift;

            $c->render( template => 'index');

            # Check provisionning
            $c->on(finish => sub {
                    shift->provisionning();
                }
            );
        }
    )->name('index');

    $r->post('/' => sub {
            my $c      = shift;
            my $upload = $c->param('file');

            my ($mediatype, $encoding) = by_suffix $upload->filename;

            my ($msg, $short);
            # Check file type
            if (index($mediatype, 'image') >= 0) {
                # Create directory if needed
                mkdir('files', 0700) unless (-d 'files');

                if(LutimModel->begin) {
                    my @records = LutimModel::Lutim->select('WHERE path IS NULL LIMIT 1');
                    if (scalar(@records)) {
                        # Save file and create record
                        my $filename = $upload->filename;
                        my $ext      = ($filename =~ m/([^.]+)$/)[0];
                        my $path     = 'files/'.$records[0]->short.'.'.$ext;
                        $upload->move_to($path);
                        $records[0]->update(
                            path                 => $path,
                            filename             => $filename,
                            mediatype            => $mediatype,
                            footprint            => digest_file_hex($path, 'SHA-512'),
                            enabled              => 1,
                            delete_at_day        => ($c->param('delete-day')) ? 1 : 0,
                            delete_at_first_view => ($c->param('first-view')) ? 1 : 0,
                            created_at           => time(),
                            created_by           => $c->tx->remote_address
                        );

                        # Log image creation
                        $c->app->log->info('[CREATION] '.$c->tx->remote_address.' pushed '.$filename.' (path: '.$path.')');

                        # Give url to user
                        $short = $records[0]->short;
                    } else {
                        # Houston, we have a problem
                        $msg = $c->l('no_more_short', $c->config->{contact});
                    }
                }
                LutimModel->commit;
            } else {
                $msg = $c->l('no_valid_file', $upload->filename);
            }

            # Check provisionning
            $c->on(finish => sub {
                    shift->provisionning();
                }
            );

            if (defined($c->param('format')) && $c->param('format') eq 'json') {
                if (defined($short)) {
                    $msg = {
                        filename => $upload->filename,
                        short    => $short
                    };
                } else {
                    $msg = {
                        filename => $upload->filename,
                        msg      => $msg
                    };
                }
                $c->render(
                    json => {
                        success => (defined($short)) ? Mojo::JSON->true : Mojo::JSON->false,
                        msg     => $msg
                    }
                );
            } else {
                $c->flash(msg      => $msg)   if (defined($msg));
                $c->flash(short    => $short) if (defined($short));
                $c->flash(filename => $upload->filename);
                $c->redirect_to('/');
            }
        }
    )->name('add');

    $r->get('/:short' => sub {
        my $c     = shift;
        my $short = $c->param('short');
        my $dl    = (defined($c->param('dl'))) ? 'attachment' : 'inline';

        my @images = LutimModel::Lutim->select('WHERE short = ? AND ENABLED = 1 AND path IS NOT NULL', $short);

        if (scalar(@images)) {
            if($images[0]->delete_at_day && $images[0]->created_at + 86400 <= time()) {
                # Log deletion
                $c->app->log->info('[DELETION] '.$c->tx->remote_address.' tried to view '.$images[0]->filename.' but it has been removed by expiration (path: '.$images[0]->path.')');

                # Delete image
                unlink $images[0]->path();
                $images[0]->update(enabled => 0);

                # Warn user
                $c->flash(
                    msg => $c->l('image_not_found')
                );
                return $c->redirect_to('/');
            }
            if($c->render_file($images[0]->filename, $images[0]->path, $images[0]->mediatype, $dl) != 500) {
                # Update counter and check provisionning
                $c->on(finish => sub {
                    # Log access
                    $c->app->log->info('[VIEW] '.$c->tx->remote_address.' viewed '.$images[0]->filename.' (path: '.$images[0]->path.')');

                    # Update record
                    my $counter = $images[0]->counter + 1;
                    $images[0]->update(counter => $counter);

                    $images[0]->update(last_access_at => time());
                    $images[0]->update(last_access_by => $c->tx->remote_address);

                    # Delete image if needed
                    if ($images[0]->delete_at_first_view) {
                        # Log deletion
                        $c->app->log->info('[DELETION] '.$c->tx->remote_address.' made '.$images[0]->filename.' removed (path: '.$images[0]->path.')');

                        # Delete image
                        unlink $images[0]->path();
                        $images[0]->update(enabled => 0);
                    }

                    shift->provisionning();
                });
            }
        } else {
            @images = LutimModel::Lutim->select('WHERE short = ? AND ENABLED = 0 AND path IS NOT NULL', $short);

            if (scalar(@images)) {
                # Log access try
                $c->app->log->info('[NOT FOUND] '.$c->tx->remote_address.' tried to view '.$short.' but it does\'nt exist.');

                # Warn user
                $c->flash(
                    msg => $c->l('image_not_found')
                );
                return $c->redirect_to('/');
            } else {
                # Image never existed
                $c->render_not_found;
            }
        }
    })->name('short');
}

1;