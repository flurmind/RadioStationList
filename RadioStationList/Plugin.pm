package Plugins::RadioStationList::Plugin;

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::OPMLBased);

use URI::Escape qw(uri_escape_utf8);
use Encode qw(encode_utf8 decode_utf8);
use JSON::XS qw(decode_json);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use Slim::Utils::Timers;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Web::Pages;
use Slim::Web::HTTP;
use Slim::Control::Request;
use Slim::Control::XMLBrowser;
use Slim::Networking::SimpleAsyncHTTP;

use Time::HiRes qw();
use File::Spec;
use File::Path qw(mkpath);
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use Digest::MD5 qw(md5_hex);

# Стабильный костяк узлов Radio Browser.
# Обновляется вместе с плагином если меняется инфраструктура.
# Актуальный список: https://www.radio-browser.info/
my @_RB_MIRRORS = (
    'https://all.api.radio-browser.info',  # round-robin, сам выбирает живой
    'https://de1.api.radio-browser.info',
    'https://de2.api.radio-browser.info',
    'https://nl1.api.radio-browser.info',
    'https://at1.api.radio-browser.info',
);

my $prefs = preferences('plugin.radiostationlist');
my $log;
my $cached_menu_items;
my %_search_inflight;
my %_api_response_cache;
my %_request_gen;
# Регистр реально скачанных диапазонов для каждого поискового терма
my %_chunk_index;  # search_term => [ [start, len, requested_limit], ... ]
my %_chunk_term_seen; # search_term => время последнего обращения, для LRU-зачистки
my %_logo_verify_cache;   # source_path => { mtime, size, ext, ok }

our $plugin_dir = dirname(__FILE__);
our %downloading;
our %failed_downloads; 
our %permanent_failures; # Для необратимо битых ссылок
our %pending_timers;
our %icon_subscribers; # icon_url => [ [url_md5, station_name, station_url], ... ] — кто ждёт именно эту картинку
our %icon_inflight;    # icon_url => 1, если по нему прямо сейчас реально летит HTTP-запрос
our %icon_inflight_since = ();# icon_url => time() старта реальной HTTP-попытки; второй, независимый от %downloading предохранитель для GC зависших группово-скачиваемых иконок (см. _update_station_cache)
our %icon_retry_attempts; # Счётчик страйков ПО ИКОНКЕ (для dedup-группы)
our %icon_retry_last_attempt;  # icon_url => время последнего страйка — нужно для TTL-очистки в Settings.pm
our %custom_logo_active_urls;
our $mirror_discovery_fail_count = 0;

my @icon_download_queue;           # FIFO буфер заданий на закачку иконок
my $active_icon_downloads = 0;     # сколько реальных HTTP-запросов сейчас открыто
my $ICON_DOWNLOAD_CONCURRENCY = 4; # лимит одновременных закачек
my %icon_queued;                   # url_md5 => 1, если задание уже стоит в очереди (анти-дубль)
my $_discovery_inflight = 0;

my @DEFAULT_STATIONS = (
    {
        name        => '1.FM - Ambient Psychill',
        url         => 'http://strm112.1.fm/ambientpsy_mobile_mp3',
        icon        => 'https://www.radioplayeruk.com/img/logs/1fmambientpsychill.png',
        tags        => 'Ambient, Chillout, Psychill',
        countrycode => 'CH',
        country     => 'Switzerland',
        homepage    => 'https://radio.1cloud.fm',
        bitrate     => 256,
        codec       => 'MP3',
    },
);

sub initPlugin {
	my $class = shift;
	
	$log = Slim::Utils::Log->addLogCategory({
		category     => 'plugin.radiostationlist',
		defaultLevel => 'WARN',
		description  => 'PLUGIN_RADIOSTATIONLIST_LOG_DESC',
	});
	
	$prefs->init({ 
		stations        => \@DEFAULT_STATIONS, 
		custom_logo_dir => '',
		search_limit    => 100,
		show_subtext    => 1,
		allow_webp_playlist => 0,
		use_icon_proxy  => 0,
	});
	
	# Чистим осиротевшие .tmp, оставшиеся после аварийного завершения процесса
	my $logo_dir = File::Spec->catdir($plugin_dir, 'HTML', 'EN', 'plugins', 'RadioStationList', 'html', 'RadioLogo');
	if (-d $logo_dir && opendir(my $dh, $logo_dir)) {
		while (my $file = readdir($dh)) {
			next unless $file =~ /^[a-f0-9]{32}\.(?:png|jpg|jpeg|gif|ico|svg|webp)\.tmp$/i;
			unlink(File::Spec->catfile($logo_dir, $file))
				and $log->debug("[STARTUP-GC] Removed leftover tmp file: $file");
		}
		closedir($dh);
	}
	
	_update_station_cache();

	my $app_icon = 'html/images/radio.png';
	
	$class->SUPER::initPlugin(
		feed   => \&_topLevel,
		tag    => 'radiostationlist',
		menu   => 'radios',
		is_app => 0,
		icon   => $app_icon,
	);

	if (main::WEBUI) {
		require Plugins::RadioStationList::Settings;
		Plugins::RadioStationList::Settings->new($class);
	}
	$log->info("Plugin initialized successfully.");
	Slim::Control::Request::subscribe(\&_onPlayEvent, [['playlist'], ['newsong']]);
	_refresh_mirrors_list(); # Запускаем асинхронный поиск зеркал
	
	Slim::Control::Request::addDispatch(
		['radiostationlistinfo', 'items', '_index', '_quantity'],
		[0, 1, 1, \&_stationInfoCliQuery]
	);
	
	if (main::WEBUI) {
		# Регистрируем сырой обработчик для выдачи WebP в браузер
		Slim::Web::Pages->addRawFunction(
			qr{plugins/RadioStationList/webp-preview/},
			\&_serveWebpPreview
		);
	}
}	

sub _topLevel {
	my ($client, $callback) = @_;
	my @items;
	
	push @items, {
		name => Slim::Utils::Strings::string('RR_SEARCH_RADIO_BROWSER') || 'Search Radio Browser',
		type => 'search',
		url  => \&_searchRadioBrowser,
		icon => 'html/images/search.png',
	};

	if ($cached_menu_items && @$cached_menu_items) {
		push @items, @$cached_menu_items;
	}
	
	$callback->({items => \@items,});
}

sub getDisplayName { 'RADIO_STATION_LIST' }

# ============================================================
# CACHE & LOGO MANAGEMENT 
# ============================================================

# ─────────────────────────────────────────────────────────────
# PURE HELPERS
# Функции без side-effects. Только трансформация данных.
# ─────────────────────────────────────────────────────────────

# _get_url_hash: Возвращает MD5 хэш от URL
sub _get_url_hash {
    my ($url) = @_;
    
    # Не генерируем фейковый хэш для пустого URL
    return '' unless $url;
    
    return md5_hex(encode_utf8($url));
}

sub _log_path {
    my $path = shift;
    return eval { Encode::decode_utf8($path) } || $path;
}

# _detect_image_extension: Чистая функция проверки magic bytes.
# Возвращает расширение или undef.
sub _detect_image_extension {
    my ($content) = @_;
    
    return undef unless $content && length($content) > 100 && length($content) < 5242880;
    # Отсекаем явный HTML, но ищем <svg где угодно в первых 256 байтах
    my $header = substr($content, 0, 1024);
    return undef if $header =~ /^\s*</ && $header !~ /<svg/is;

    # PNG
    if (length($content) >= 24 && $content =~ /^\x89PNG\r\n\x1a\n/) {
        my $ihdr_type   = substr($content, 12, 4);
        my $ihdr_length = unpack('N', substr($content, 8, 4));
        my $width       = unpack('N', substr($content, 16, 4));
        my $height      = unpack('N', substr($content, 20, 4));
        return 'png' if $ihdr_type eq 'IHDR' && $ihdr_length == 13 && $width > 0 && $height > 0;
    }
    # JPEG
    elsif ($content =~ /^\xFF\xD8\xFF/) { return 'jpg'; }
    # GIF
    elsif ($content =~ /^GIF8/)         { return 'gif'; }
    # SVG
    elsif ($header =~ /<svg/is) { return 'svg'; }
    # WEBP
    elsif ($content =~ /^RIFF....WEBP/s){ return 'webp'; }
    # ICO
    elsif ($content =~ /^\x00\x00\x01\x00/) { return 'ico'; }

    return undef;
}

# ─────────────────────────────────────────────────────────────
# I/O & FILE SYSTEM
# Изолированная работа с файлами и движком LMS
# ─────────────────────────────────────────────────────────────

# Прогоняет файл через движок LMS
sub _verify_image_with_lms {
    my ($filepath, $ext) = @_;
	my $display_path = _log_path($filepath);

    return 0 if !-e $filepath || -s $filepath < 12;

    # === Доверяем не расширению из URL, а реальным магическим байтам ===
    my $real_format = _detect_real_format($filepath);
    if ($real_format ne 'unknown') {
        my $ext_norm = $ext =~ /^jpe?g$/i ? 'jpeg' : lc($ext);
        if ($real_format ne $ext_norm) {
            $log->warn("[VERIFY-MISMATCH] Expected ext='$ext', but got '$real_format' — $display_path");
        }
        $ext = $real_format eq 'jpeg' ? 'jpg' : $real_format;  # дальше проверяем по факту, не по URL
    } else {
		$log->warn("[VERIFY] Could not detect real format for '$display_path'");
        return 0; # Рубим всё, что не опознали по содержимому
    }
	# Теперь безопасно пропускаем вектор/иконки, так как мы ПОДТВЕРДИЛИ их содержимое
    return 1 if $ext =~ /^(svg|ico)$/;
	
    # === СТРОГАЯ ПРОВЕРКА WEBP НА ЦЕЛОСТНОСТЬ ===
    if ($ext eq 'webp') {
        if (!-e $filepath || -s $filepath < 12) {
            $log->warn("[VERIFY] WebP file is empty or too small.");
            return 0;
        }
        
        # Читаем первые 12 байт заголовка RIFF/WEBP
        open my $fh, '<', $filepath or return 0;
        binmode $fh;
        read $fh, my $header, 12;
        close $fh;
        
        # Распаковываем заголовок: 4 символа, 32-битное целое (размер), 4 символа
        my ($riff, $header_size, $webp) = unpack("A4VA4", $header);
        
        if ($riff eq 'RIFF' && $webp eq 'WEBP') {
            my $actual_size   = -s $filepath;
            my $expected_size = $header_size + 8; # Размер в заголовке + 8 байт самого заголовка
            
            $log->debug("[VERIFY-WEBP-INFO] Station file: $display_path. Actual size: $actual_size bytes, Expected by header: $expected_size bytes");
            
            if ($actual_size < $expected_size) {
                $log->warn("[VERIFY] WebP file is TRUNCATED (corrupted)! Rejecting.");
                return 0; # БРАКУЕМ! Файл недокачан.
            }
            return 1; # Файл целый, пускаем.
        } else {
            $log->warn("[VERIFY] File has .webp extension but invalid magic bytes.");
            return 0; # БРАКУЕМ! Это не WebP.
        }
    }
    # ============================================
    # === СТРОГАЯ ПРОВЕРКА JPEG (маркер EOI = FF D9) ===
    if ($ext =~ /^jpe?g$/i) {
        open my $fh, '<', $filepath or return 0;
        binmode $fh;
        seek $fh, -2, 2;
        read $fh, my $footer, 2;
        close $fh;
        my $hex = unpack("H*", $footer);
        my $actual_size = -s $filepath;
        $log->debug("[VERIFY-JPEG] $display_path size=$actual_size ending=$hex");
        if ($hex ne 'ffd9') {
            $log->warn("[VERIFY] JPEG CORRUPTED (without EOI-marker FFD9)! Rejecting.");
            return 0;
        }
    }

    # === СТРОГАЯ ПРОВЕРКА PNG (чанк IEND) ===
    if ($ext eq 'png') {
        open my $fh, '<', $filepath or return 0;
        binmode $fh;
        seek $fh, -12, 2;
        read $fh, my $footer, 12;
        close $fh;
        if ($footer !~ /IEND/) {
            $log->warn("[VERIFY] PNG CORRUPTED (without IEND)! Rejecting.");
            return 0;
        }
    }

    my $is_valid = 0;

    eval {
        require Slim::Utils::GDResizer;
        my ($ref) = Slim::Utils::GDResizer->resize(file => $filepath, width => 50, height => 50, mode => 'o');
        $is_valid = 1 if $ref && length($$ref) > 0;
    };
    if ($@) {
        $log->warn("[VERIFY] GDResizer EXCEPTION for '$display_path' (ext=$ext): $@");
    } elsif (!$is_valid) {
        $log->warn("[VERIFY] GDResizer returned empty result for '$display_path' (ext=$ext)");
    }
    
    return $is_valid;
}

sub _detect_real_format {
    my ($filepath) = @_;
    open my $fh, '<', $filepath or return 'unknown';
    binmode $fh;
    read $fh, my $magic, 1024;  # 256 всё ещё мало: лицензионный комментарий + DOCTYPE у flaticon/iconfinder-иконок легко занимает 260-300+ байт
    close $fh;
    return 'webp' if substr($magic,0,4) eq 'RIFF' && substr($magic,8,4) eq 'WEBP';
    return 'png'  if substr($magic,0,8) eq "\x89PNG\x0d\x0a\x1a\x0a";
    return 'jpeg' if substr($magic,0,2) eq "\xff\xd8";
    return 'gif'  if substr($magic,0,4) eq 'GIF8';
    return 'ico'  if substr($magic,0,4) eq "\x00\x00\x01\x00";
    return 'svg'  if $magic =~ /<svg/is;
    return 'unknown';
}

# Синхронизирует локальные логотипы в кэш
sub _process_custom_logos {
    my ($stations, $logo_dir, $force_rescan) = @_;
	my $changed_count = 0;

    my $custom_logo_dir_pref = $prefs->get('custom_logo_dir') || '';
    my $my_logo_dir = $custom_logo_dir_pref
        ? $custom_logo_dir_pref
        : File::Spec->catdir((Slim::Utils::OSDetect::dirsFor('cache'))[0], 'MyRadioLogo');
    
	our $_last_bad_logo_dir //= ''; # Глобальная переменная для подавления спама

    eval { mkpath($logo_dir) }    unless -d $logo_dir;
    eval { mkpath($my_logo_dir) } unless -d $my_logo_dir;
    
    # Если папка так и не появилась (например, нет прав на запись)
    unless (-d $my_logo_dir) {
        if ($_last_bad_logo_dir ne $my_logo_dir) {
            $log->warn("Cannot create or access custom logo dir '$my_logo_dir'. Please check path and permissions.");
            $_last_bad_logo_dir = $my_logo_dir;
        }
        return 0; # Возвращаем 0, так как изменений нет
    }
    
	# Снимок ДО пересчёта — нужен, чтобы поймать станции, которые лишились
    # локального логотипа с прошлого прохода (файл удалили/переименовали вручную).
    
	my %was_active = %custom_logo_active_urls;
    # Полный пересчёт на каждый вызов: только URL, у которых ПРЯМО СЕЙЧАС есть
    # валидное совпадение по имени файла, помечаются как "локальный источник".
    # Settings.pm читает этот хэш в _prepare_display_stations, чтобы решить,
    # показывать ли бейдж папки — icon-поле для этого больше не индикатор.
    %custom_logo_active_urls = ();
	
    # Индекс: lc(имя) -> [url1, url2]
	my %station_map;
	for my $st (@$stations) {
		# Локальный файл — единственный источник правды при совпадении по имени:
		# перекрывает icon-поле независимо от того, пусто оно, рабочее или битое.
		$station_map{lc($st->{name})} //= [];
		push @{ $station_map{lc($st->{name})} }, $st->{url} if $st->{name} && $st->{url};
	}

	opendir(my $dh, $my_logo_dir) or do {
        if ($_last_bad_logo_dir ne $my_logo_dir) {
            $log->warn("Cannot open custom logo dir '$my_logo_dir': $!");
            $_last_bad_logo_dir = $my_logo_dir;
        }
        return 0;
    };
    
    $_last_bad_logo_dir = ''; # Если дошли сюда, папка рабочая — сбрасываем предохранитель
    
    while (my $file = readdir($dh)) {
        next if $file =~ /^\./;
        my $decoded_file = eval { decode_utf8($file, 1) } // $file;
        
        next unless $decoded_file =~ /^(.*)\.(png|jpg|jpeg|gif|ico|svg)$/i;
        my ($base_name, $ext) = ($1, lc($2));

        my $urls_ref = $station_map{lc($base_name)};
        next unless $urls_ref;

		my $source    = File::Spec->catfile($my_logo_dir, $decoded_file);
		my $src_mtime = (stat($source))[9] || 0;
		my $src_size  = (stat($source))[7] || 0;

		my $cached = $force_rescan ? undef : $_logo_verify_cache{$source};
        # ДИАГНОСТИКА: прогоняем кастомный файл через тот же движок, что и
        # скачанные иконки — чтобы понять, реально ли GD умеет его декодировать,
        # а не просто "браузер на странице настроек смог это нарисовать".
		my $verified;
		if ($cached && $cached->{mtime} == $src_mtime && $cached->{size} == $src_size && $cached->{ext} eq $ext) {
			# Файл не менялся со времени прошлой проверки — берём готовый результат,
			# не трогаем диск и GD повторно (не важно, был он тогда годным или битым)
			$verified = $cached->{ok};
		} else {
			$verified = _verify_image_with_lms($source, $ext);
			$_logo_verify_cache{$source} = { mtime => $src_mtime, size => $src_size, ext => $ext, ok => $verified };
			$log->warn("[VERIFY-CUSTOM] '$decoded_file' REJECTED by LMS graphics engine — skipping copy to cache.")
				unless $verified;
		}

		for my $st_url (@$urls_ref) {
            my $hash      = _get_url_hash($st_url);
            my $dest      = File::Spec->catfile($logo_dir, "$hash.$ext");
            my $dst_mtime = (-e $dest) ? (stat($dest))[9] || 0 : 0;
            my $dst_size  = (-e $dest) ? (stat($dest))[7] || 0 : 0;
            next unless $verified;
			# Помечаем ДО copy(): даже если файл уже актуален и копирование
            # пропущено ниже — станция всё равно ПРЯМО СЕЙЧАС обслуживается
            # локальным файлом, а не скачанным по URL.
            $custom_logo_active_urls{$st_url} = 1;
			if ($force_rescan || !-e $dest || $src_mtime > $dst_mtime || $src_size != $dst_size) {
                if (copy($source, $dest)) {
					$changed_count++;
                    $log->debug("Local logo '$decoded_file' copied to cache as " . basename($dest));
                    # Удаляем старые файлы других форматов для этого хэша
                    for my $old_ext (qw(png jpg jpeg gif ico svg webp)) {
                        next if $old_ext eq $ext;
                        my $old_path = File::Spec->catfile($logo_dir, "$hash.$old_ext");
                        if (-e $old_path) {
                            unlink $old_path;
                            $log->debug("Removed old cache '$hash.$old_ext' after format change to '$ext'");
                        }
                    }
                }
            }
        }	
    }
    closedir($dh);
    # Станции, которые раньше обслуживались локальным файлом, а теперь нет —
    # исходник пропал, значит и скопированный в кэш файл больше не валиден.
    for my $url (keys %was_active) {
        next if $custom_logo_active_urls{$url};   # всё ещё активен — не трогаем
        my $hash = _get_url_hash($url);
        for my $ext (qw(png jpg jpeg gif ico svg webp)) {
            my $path = File::Spec->catfile($logo_dir, "$hash.$ext");
            if (-e $path) {
                unlink $path;
				$changed_count++;
                $log->debug("Cleared cache '$hash.$ext' — custom logo source no longer present");
            }
        }
    }

	$log->debug("[CUSTOM-LOGO] _process_custom_logos finished, changed=$changed_count") if $changed_count;
	return $changed_count;
}

# Ищет логотип на диске, возвращает расширение или undef
sub _find_cached_logo {
    my ($logo_dir, $url_md5) = @_;
    for my $ext (qw(png jpg jpeg gif ico svg webp)) {
        return $ext if -e File::Spec->catfile($logo_dir, "$url_md5.$ext");
    }
    return undef;
}

# ─────────────────────────────────────────────────────────────
# NETWORK & DOWNLOAD LIFECYCLE (Обработка 200 OK)
# ─────────────────────────────────────────────────────────────

sub _handle_icon_download_success {
    my ($http, $url_md5, $station_name, $station_url, $logo_dir, $station_icon_url) = @_;
    my $content = $http->content;
    
	# 1. Content-Type Guard
	my $ct = $http->headers->content_type || '';
	if ($ct && $ct !~ m{^image/}i) {
		_maybe_try_proxy_or_fail($station_name, $station_url, $station_icon_url, $url_md5, "bad content-type [$ct]");
		return;
	}

	# 2. Magic Bytes / Data Integrity Guard
	my $ext = _detect_image_extension($content);
	if (!$ext) {
		_maybe_try_proxy_or_fail($station_name, $station_url, $station_icon_url, $url_md5, "integrity check failed (bad magic bytes)");
		return;
	}

    # 3. Disk Write
    my $filepath = File::Spec->catfile($logo_dir, "$url_md5.$ext");
    eval {
        open(my $fh, '>:raw', "$filepath.tmp") or die $!;
        print $fh $content;
        close $fh;
        rename("$filepath.tmp", $filepath) or die "Rename failed: $!";
    };
    if ($@) {
        $log->error("Failed to write downloaded file: $@");
        _maybe_try_proxy_or_fail($station_name, $station_url, $station_icon_url, $url_md5, "disk write failed: $@", 1); 
        return;
    }
	# Подчищаем файлы с тем же хэшем, но другим расширением — формат
    # картинки на удалённой стороне мог смениться без смены icon_url.
    for my $other_ext (qw(png jpg jpeg gif ico svg webp)) {
        next if $other_ext eq $ext;
        my $stale = File::Spec->catfile($logo_dir, "$url_md5.$other_ext");
        unlink($stale) if -e $stale;
    }
	# === Логируем размер сразу после записи на диск ===
    my $downloaded_size = -e $filepath ? -s $filepath : 0;
    $log->debug("[DOWNLOAD-INFO] '$station_name' saved to disk. Size: $downloaded_size bytes, Format: $ext, URL-MD5: $url_md5");
    # ============================================================
	# 4. LMS Graphics Engine Guard
	if (!_verify_image_with_lms($filepath, $ext)) {
		unlink($filepath);
		$log->warn("LMS graphics engine REJECTED '$station_name' (corrupted/truncated download).");
		_maybe_try_proxy_or_fail($station_name, $station_url, $station_icon_url, $url_md5, "corrupted download", 1);
		return;
	}
	# Success
    # === Изменено на ->info и добавлен точный размер ===
    $log->info("Logo successfully verified & saved for '$station_name' ($ext). Final size: $downloaded_size bytes.");
    delete $failed_downloads{$station_url}; 
    delete $permanent_failures{$station_url};
    delete $icon_retry_attempts{$station_icon_url};
	delete $icon_retry_last_attempt{$station_icon_url};
	
	# === ДЕДУП: раздаём тот же файл всем, кто ждал этот icon_url ===
	_release_icon_slot($station_icon_url);
    my $subs = delete $icon_subscribers{$station_icon_url} || [];
	my @to_copy = grep { $_->[0] ne $url_md5 } @$subs;
	my $total_waiters = scalar(@$subs);
	my $copied_count   = scalar(@to_copy);

	# Тег [DEDUP] — только когда реально было кому раздавать файл. Для сольной
	# закачки (станция сама себе единственный подписчик) "[DEDUP]" в логе вводит
	# в заблуждение, будто сработала дедупликация, хотя делить было не с кем.
	if ($copied_count > 0) {
		$log->debug(
			"[DEDUP] '$station_icon_url' resolved: " .
			"waiters=$total_waiters, copied_to=$copied_count " .
			"(skipped MD5-match for " . ($total_waiters - $copied_count) . ")"
		);
	} else {
		$log->debug("'$station_icon_url' resolved: solo download, no other subscribers.");
	}
	for my $sub (@$subs) {
        my ($sub_md5, $sub_name, $sub_url) = @$sub;
        next if $sub_md5 eq $url_md5;# Своему файлу копию не делаем
		# Снимаем блокировки/ошибки для всех подписчиков, даже если не копируем
        delete $downloading{$sub_md5};
        delete $failed_downloads{$sub_url};
        delete $permanent_failures{$sub_url};

        my $sub_dest = File::Spec->catfile($logo_dir, "$sub_md5.$ext");
        if (copy($filepath, $sub_dest)) {
            $log->info(" [DEDUP] Shared icon copied for '$sub_name' ($sub_md5.$ext)");
        } else {
            $log->warn("[DEDUP] Copy failed for '$sub_name': $!");
        }
    }
    _trigger_cache_update() if @$subs;
}

# Обработка 4xx/5xx/Timeouts
sub _strike_or_ban {
    my ($station_icon_url, $group, $log_reason, $lead_name, $lead_url, $lead_md5) = @_;
    my $n = scalar @$group;
    $icon_retry_attempts{$station_icon_url}++;
    $icon_retry_last_attempt{$station_icon_url} = time();

    if ($icon_retry_attempts{$station_icon_url} >= 2) {
        delete $icon_retry_attempts{$station_icon_url};
        delete $icon_retry_last_attempt{$station_icon_url};
        $log->warn("2nd strike for icon '$station_icon_url' ($log_reason) — banning $n station(s).");
        for my $m (@$group) {
            my ($m_md5, $m_name, $m_url) = @$m;
            delete $downloading{$m_md5};
            $permanent_failures{$m_url} = 1;
            delete $failed_downloads{$m_url};
        }
        return;
    }

    $log->warn("$log_reason for icon '$station_icon_url'. Strike $icon_retry_attempts{$station_icon_url}/2 ($n station(s)).");
    for my $m (@$group) {
        my ($m_md5, $m_name, $m_url) = @$m;
        delete $downloading{$m_md5};
        $failed_downloads{$m_url} = time();
    }
	# Сохраняем остальных участников группы (кроме lead), чтобы дедуп-раздача
    # в _handle_icon_download_success нашла их и скопировала файл, а не заставляла
    # каждого качать заново отдельно через 20с.
    my @rest = grep { $_->[0] ne $lead_md5 } @$group;
    $icon_subscribers{$station_icon_url} = \@rest if @rest;
	
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 20, sub {
        # За эти 20с станция могла сменить URL — $lead_url/$lead_md5 в замыкании
        # протухли. Переснимаем актуальное состояние из prefs перед ретраем.
        my ($cur_name, $cur_url, $cur_md5) = _find_active_station_by_icon($station_icon_url);
        return unless $cur_url; # этой иконкой больше никто не пользуется — ретрай не нужен

        return if $permanent_failures{$cur_url} || $downloading{$cur_md5};
        _enqueue_icon_download($station_icon_url, $cur_md5, $cur_name, $cur_url);
    });
}

# Ищет станцию, которая ПРЯМО СЕЙЧАС (по актуальным prefs) использует данный
# icon_url — нужен ретраю выше, чтобы не долбить по URL, которого уже нет.
sub _find_active_station_by_icon {
    my ($icon_url) = @_;
    return () unless $icon_url;
    for my $st (@{ $prefs->get('stations') || [] }) {
        next unless $st->{url} && ($st->{icon} // '') eq $icon_url;
        return ($st->{name} // '', $st->{url}, _get_url_hash($st->{url}));
    }
    return ();
}

sub _handle_icon_download_error {
    my ($http, $station_name, $station_url, $station_icon_url, $url_md5) = @_;

    my $err  = $http ? ($http->error || 'Unknown error') : 'Watchdog timeout (no response)';
    my $code = $http ? ($http->code  || 0) : 0;

    my $use_proxy = $prefs->get('use_icon_proxy') // 1;
    $log->debug(sprintf("Error for '%s' (url=%s). Code: %s, Error: %s", $station_name, $station_icon_url, $code, $err));

    if ($code == 403 || $code == 404 || $err =~ /404|Not\s*Found|403|Forbidden/i) {
        _maybe_try_proxy_or_fail($station_name, $station_url, $station_icon_url, $url_md5, "HTTP $code", 0);
        return;
    }
    if ($use_proxy) {
        _maybe_try_proxy_or_fail($station_name, $station_url, $station_icon_url, $url_md5, "network error ($err)", 0);
        return;
    }
    _release_icon_slot($station_icon_url);
    my $group = delete $icon_subscribers{$station_icon_url} || [[$url_md5, $station_name, $station_url]];
    _strike_or_ban($station_icon_url, $group, "NETWORK ERROR ($code): $err", $station_name, $station_url, $url_md5);
}

# Единая точка решения: пробуем wsrv.nl прокси один раз, иначе — окончательный бан.
# Защита от каскада страйков: если URL уже содержит wsrv.nl (т.е. это была прокси-попытка),
# повторно прокси не пробуем — сразу баним.
sub _maybe_try_proxy_or_fail {
    my ($station_name, $station_url, $station_icon_url, $url_md5, $reason, $retryable) = @_;
    my $use_proxy    = $prefs->get('use_icon_proxy') // 1;
    my $is_via_proxy = ($station_icon_url // '') =~ m{wsrv\.nl};

    _release_icon_slot($station_icon_url);
    my $group = delete $icon_subscribers{$station_icon_url} || [[$url_md5, $station_name, $station_url]];

    # 1. Переключение на прокси wsrv.nl при ошибке прямого скачивания
    if ($use_proxy && $station_icon_url && !$is_via_proxy) {
		my $proxy_url = 'https://wsrv.nl/?url=' . URI::Escape::uri_escape_utf8($station_icon_url) . '&output=png&n=-1';
        $log->info(sprintf("[PROXY] Switch to wsrv.nl for '%s' (trigger: %s)", $station_name, $reason));

        for my $m (@$group) {
            my ($m_md5, $m_name, $m_url) = @$m;
            delete $downloading{$m_md5};
            $failed_downloads{$m_url} = time();
        }
        my @rest = grep { $_->[0] ne $url_md5 } @$group;
        $icon_subscribers{$proxy_url} = \@rest if @rest;
        _enqueue_icon_download($proxy_url, $url_md5, $station_name, $station_url);

    # 2. Прокси выключен или не применим, но ошибку можно повторить (учет страйков)
    } elsif ($retryable && !$is_via_proxy) {
        $log->debug(sprintf("[RETRY] Registering strike for '%s' (trigger: %s, proxy_enabled=%s)", 
            $station_name, $reason, ($use_proxy ? 'YES' : 'NO')));
        _strike_or_ban($station_icon_url, $group, $reason, $station_name, $station_url, $url_md5);

    # 3. Окончательный отказ (уже пробовали через прокси или фатальный сбой)
    } else {
        my $fail_note = $is_via_proxy ? "proxy attempt failed" 
                      : (!$use_proxy  ? "proxy disabled in settings" 
                      : "non-retryable failure");
                      
        $log->warn(sprintf("[FAIL] Permanent failure for '%s' (trigger: %s, details: %s)", 
            $station_name, $reason, $fail_note));

        for my $m (@$group) {
            my ($m_md5, $m_name, $m_url) = @$m;
            delete $downloading{$m_md5};
            $permanent_failures{$m_url} = 1;
            delete $failed_downloads{$m_url};
        }
    }
}

sub _release_icon_slot {
    my ($icon_url) = @_;
    return unless delete $icon_inflight{$icon_url};
	delete $icon_inflight_since{$icon_url};
    $active_icon_downloads-- if $active_icon_downloads > 0;
    _process_icon_download_queue();
    return 1;
}

sub _enqueue_icon_download {
    my ($icon_url, $url_md5, $station_name, $station_url) = @_;
    return if $icon_queued{$url_md5};
    $icon_queued{$url_md5} = 1;
    push @icon_download_queue, [$icon_url, $url_md5, $station_name, $station_url];
    _process_icon_download_queue();
}

sub _process_icon_download_queue {
    while ($active_icon_downloads < $ICON_DOWNLOAD_CONCURRENCY && @icon_download_queue) {
        my $task = shift @icon_download_queue;
        delete $icon_queued{$task->[1]};
        _async_download_icon(@$task);
    }
}

# Единая точка сброса состояния закачки иконок. Список "что чистим" живёт здесь,
# а не в Settings.pm — при добавлении новой структуры состояния (как сейчас с очередью)
# правится только этот файл, вызывающий код ничего не должен знать про детали.
sub _reset_icon_error_state {
    %permanent_failures    = ();
    %failed_downloads      = ();
    %icon_inflight         = ();
    %icon_subscribers      = ();
    %icon_retry_attempts   = ();
	%icon_retry_last_attempt  = ();
	%icon_inflight_since = ();
    %downloading           = ();
    @icon_download_queue   = ();
    %icon_queued           = ();
    $active_icon_downloads = 0;
}

sub _async_download_icon {
    my ($icon_url, $url_md5, $station_name, $station_url) = @_;

    my $is_proxy_request = ($icon_url =~ m{wsrv\.nl});
    # Guards перед запуском — тихий выход, как и раньше, лог тут не нужен:
    # реальной попытки скачивания ещё не было.
    return if $downloading{$url_md5} || $permanent_failures{$station_url};
	
    if ($icon_url =~ /\.(mp3|aac|aacp|m3u|m3u8|pls|ogg|flac|wav|wma|asf|opus)(?:[\?\#]|$)/i) {
        $log->debug("URL '$station_name' looks like audio stream, blocking.");
        $permanent_failures{$station_url} = 1;
        return;
    }

	$downloading{$url_md5} = time();
	my $my_download_start = $downloading{$url_md5};
	
	push @{ $icon_subscribers{$icon_url} ||= [] }, [$url_md5, $station_name, $station_url];
	if ($icon_inflight{$icon_url}) {
		# Реальный запрос уже открыт другой станцией — эта просто подписалась
		# и получит копию по готовности (см. лог "[DEDUP] Shared icon copied").
		$log->debug("[DEDUP] '$station_name' waiting on in-flight download of '$icon_url'");
		return;
	}
	$icon_inflight{$icon_url} = 1;
	$icon_inflight_since{$icon_url} = time();   # независимая метка времени
	$active_icon_downloads++; # именно здесь открывается реальный сокет
	# Логируем в момент реального старта HTTP, а не на входе в функцию — иначе
	# guard-выходы выше (already downloading / permanent fail / dedup-join)
	# рисуют "Start downloading" для запросов, которых по факту не было.
	$log->info(sprintf("Start downloading: %s (Proxy: %s)", $icon_url, ($is_proxy_request ? 'YES' : 'NO')));

	# Watchdog: если за 30 сек колбек не вызвался — перехватываем управление
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 30, sub {
		# Если по этому url_md5 сейчас идёт УЖЕ ДРУГАЯ попытка — этот watchdog устарел
		return if ($downloading{$url_md5} // 0) != $my_download_start;

		# Атомарно проверяем, снимаем inflight-метку и освобождаем слот очереди
		return unless _release_icon_slot($icon_url);
		
		# Очищаем базовый guard конкретно для этой станции (HTTP-колбек делает это сам, а мы сымитируем)
		delete $downloading{$url_md5}; 

		$log->warn("Download WATCHDOG fired for icon '$icon_url' (30s timeout)");
		
		# Делегируем всю логику (прокси, баны, подписчиков) в единый обработчик ошибок
		_handle_icon_download_error(undef, $station_name, $station_url, $icon_url, $url_md5);
		
		# Обязательно дергаем рендер/кэш, чтобы UI отреагировал на переключение
		_trigger_cache_update();
	});
    my $logo_dir = File::Spec->catdir($plugin_dir, 'HTML', 'EN', 'plugins', 'RadioStationList', 'html', 'RadioLogo');
	my $request_timeout = $is_proxy_request ? 20 : 15;
	eval {
        Slim::Networking::SimpleAsyncHTTP->new(
			sub { # SUCCESS callback
				my $http = shift;
				# 1. Guard принадлежит именно этой попытке?
				return if ($downloading{$url_md5} // 0) != $my_download_start;
				delete $downloading{$url_md5};
				
				# 2. Только теперь пишем в лог
				my $size = length($http->content);
				$log->info(
					sprintf(
						"[DOWNLOAD-OK] Station '%s': icon downloaded from %s, size=%d bytes",
						$station_name,
						$icon_url,
						$size
					)
				);
				
				_handle_icon_download_success($http, $url_md5, $station_name, $station_url, $logo_dir, $icon_url);
				_trigger_cache_update();
			},
			sub { # ERROR callback
				my $http = shift;
				# 1. Перехватываем 8-секундное "эхо" от LMS — и устаревшую попытку тоже
				return if ($downloading{$url_md5} // 0) != $my_download_start;
				delete $downloading{$url_md5};
				
				# 2. Пишем в лог только реальный первый отказ
				$log->debug(sprintf("Failed to download logo for: '%s'. Code: %s", $station_name, ($http && $http->code ? $http->code : 'No Response')));
				
				_handle_icon_download_error($http, $station_name, $station_url, $icon_url, $url_md5);
				_trigger_cache_update();
			},
            # === ЗАГОЛОВКИ ===
            {
                timeout => $request_timeout,
                headers => {
                    'User-Agent'      => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
                    'Accept'          => 'image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
                    'Accept-Language' => 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
                    'Cache-Control'   => 'max-age=0',
                    'Connection'      => 'keep-alive',
                },
            }
        )->get($icon_url); # Теперь тут остается только чистый URL!
    };
	if ($@) {
			delete $downloading{$url_md5};
			$log->error("Exception during download kickoff for '$icon_url': $@");

			# _maybe_try_proxy_or_fail сам снимет inflight-слот и заберёт РЕАЛЬНУЮ
			# группу подписчиков (эта станция там уже есть — попала push'ем выше по
			# коду ещё до попытки закачки) и обработает её по тем же правилам, что
			# и остальные ошибки: попробует прокси, либо даст 2 страйка, либо
			# забанит сразу (если это уже была прокси-попытка).
			_maybe_try_proxy_or_fail($station_name, $station_url, $icon_url, $url_md5, "exception during kickoff: $@", 1);
			_trigger_cache_update();
		}
}

# ─────────────────────────────────────────────────────────────
# ORCHESTRATOR
# Точка сборки UI списка станций
# ─────────────────────────────────────────────────────────────
sub _trigger_cache_update {
    Slim::Utils::Timers::killTimers(undef, \&_update_station_cache);
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1.0, \&_update_station_cache);
}

# --- GC ---
sub _run_icon_download_gc {
    my $stale_cutoff = time() - 60;
    for my $k (keys %downloading) {
        next if $downloading{$k} > $stale_cutoff;
        delete $downloading{$k};
        $log->warn("[GC] Cleared stale downloading-guard (md5=$k, older than 60s)");
    }

    # Второй, независимый предохранитель. %icon_inflight/%icon_subscribers снимаются
    # только через _release_icon_slot из watchdog конкретной попытки. Если этот watchdog
    # не долетел (в т.ч. если GC выше уже стёр $downloading{$url_md5} и тем самым сорвал
    # внутреннюю сверку watchdog'а "своя ли это ещё попытка") — снять inflight и
    # разбудить подписчиков больше некому. Ключуется по icon_url, от %downloading не зависит.
    my $inflight_cutoff = time() - 90;
    for my $icon_url (keys %icon_inflight_since) {
        next if $icon_inflight_since{$icon_url} > $inflight_cutoff;

        my $group  = $icon_subscribers{$icon_url};
        my $leader = ($group && @$group) ? $group->[0] : undef;

        if (_release_icon_slot($icon_url)) {
            if ($leader) {
                my ($leader_md5, $leader_name, $leader_url) = @$leader;
                delete $downloading{$leader_md5};
                $log->warn("[GC] Force-released stuck inflight icon after 90s: $icon_url (leader='$leader_name')");
                _handle_icon_download_error(undef, $leader_name, $leader_url, $icon_url, $leader_md5);
            } else {
                $log->warn("[GC] Force-released orphaned inflight icon after 90s: $icon_url (no subscribers)");
            }
        }
    }
}

sub _log_icon_cache_status {
    my $n_retrying = scalar(keys %icon_retry_attempts);
    my $n_inflight = scalar(keys %icon_inflight);
    my $n_waiting  = 0;
    $n_waiting += scalar(@{$icon_subscribers{$_}}) for keys %icon_subscribers;

    my @notes;
    push @notes, "$n_retrying icon(s) waiting to retry after a previous failure" if $n_retrying;
    push @notes, "$n_inflight icon(s) downloading right now"                     if $n_inflight;
    push @notes, "$n_waiting station(s) waiting on a shared icon download"       if $n_waiting;

    $log->debug("[ICON-CACHE] " . join(', ', @notes)) if @notes;
}

# --- Пред-проход по станциям ---
sub _build_banned_icon_urls {
    my ($stations) = @_;
    my %banned_icon_urls;
    for my $st (@$stations) {
        next unless $st->{icon} && $st->{url} && $permanent_failures{ $st->{url} };
        $banned_icon_urls{ $st->{icon} } = 1;
    }
    return \%banned_icon_urls;
}

# Единственный проход по диску за весь rebuild: url_md5/found_ext на станцию
# считаются один раз, плюс собирается "донор" на icon_url для дискового дедупа
# (кто первый на диске — тот и донор для остальных, независимо от порядка в списке).
sub _prescan_station_icons {
    my ($stations, $logo_dir) = @_;
    my %icon_source_cache;
    my @station_cache_info;
    for my $st (@$stations) {
        my $url_md5   = _get_url_hash($st->{url});
        my $found_ext = _find_cached_logo($logo_dir, $url_md5);
        push @station_cache_info, [$url_md5, $found_ext];
        $icon_source_cache{ $st->{icon} } ||= [$url_md5, $found_ext]
            if $found_ext && $st->{icon} && !$custom_logo_active_urls{ $st->{url} // '' };
    }
    return (\@station_cache_info, \%icon_source_cache);
}

# --- Один айтем меню ---
# Возвращает готовый $final_icon; попутно инкрементирует счётчики в $stats
# (from_cache/queued_download/used_default) и обновляет $icon_source_cache
# для следующих станций в основном цикле.
sub _resolve_station_icon {
    my ($st, $url_md5, $found_ext, $logo_dir, $icon_source_cache, $banned_icon_urls, $stats) = @_;

    my $url  = $st->{url};
    my $icon = $st->{icon} || '';

    if (!$found_ext && $icon && $icon_source_cache->{$icon}) {
        my ($src_md5, $src_ext) = @{ $icon_source_cache->{$icon} };
        my $src_file = File::Spec->catfile($logo_dir, "$src_md5.$src_ext");
        my $dst_file = File::Spec->catfile($logo_dir, "$url_md5.$src_ext");
        if (-f $src_file && File::Copy::copy($src_file, $dst_file)) {
            $found_ext = $src_ext;
            $log->debug("[DEDUP-DISK] '$st->{name}' reused cached file from existing station for icon: $icon");
        }
    }

    my $final_icon;

    if ($found_ext && $found_ext eq 'webp') {
        my $allow_webp = $prefs->get('allow_webp_playlist') || 0;
        if ($allow_webp) {
            $stats->{from_cache}++;
            my $cache_file = File::Spec->catfile($logo_dir, "$url_md5.$found_ext");
            my $mtime = (stat($cache_file))[9] || 0;
            $final_icon = "plugins/RadioStationList/webp-preview/$url_md5.$found_ext?v=$mtime";
        } else {
            $stats->{used_default}++;
            $final_icon = 'html/images/radio.png';
        }
    } elsif ($found_ext) {
        $stats->{from_cache}++;
        my $cache_file = File::Spec->catfile($logo_dir, "$url_md5.$found_ext");
        my $mtime      = (stat($cache_file))[9] || 0;
        $final_icon = "plugins/RadioStationList/html/RadioLogo/$url_md5.$found_ext?v=$mtime";
    } else {
        if ($icon =~ m{^https?://}i) {
            if ($icon =~ /\.(mp3|aac|aacp|m3u|m3u8|pls|ogg|flac|wav|wma|asf|opus)(?:[\?\#]|$)/i) {
                $permanent_failures{$url} = 1;
            }
            if (!$permanent_failures{$url} && $banned_icon_urls->{$icon}) {
                $permanent_failures{$url} = 1;
                $log->debug("'$st->{name}' inherits permanent ban for shared icon: $icon");
            }

            unless (
                $permanent_failures{$url}
                || $downloading{$url_md5}
                || ($icon && ($icon_retry_attempts{$icon} // 0) >= 1)
            )  {
                if (!$failed_downloads{$url} || (time() - $failed_downloads{$url} >= 20)) {
                    $stats->{queued_download}++;
                    _enqueue_icon_download($icon, $url_md5, $st->{name}, $url);
                }
            }
        }
        $stats->{used_default}++;
        $final_icon = 'html/images/radio.png';
    }

    $icon_source_cache->{$icon} = [$url_md5, $found_ext]
        if $icon && $found_ext && !$custom_logo_active_urls{$url};

    return $final_icon;
}

# --- Главная функция ---
sub _update_station_cache {
    my $stations = $prefs->get('stations') || [];
    my $logo_dir = File::Spec->catdir($plugin_dir, 'HTML', 'EN', 'plugins', 'RadioStationList', 'html', 'RadioLogo');

    # Очистка мусора (забываем ошибки удаленных станций)
    my %active_urls = map { $_->{url} => 1 } grep { $_->{url} } @$stations;
    delete $permanent_failures{$_} for grep { !$active_urls{$_} } keys %permanent_failures;
    delete $failed_downloads{$_}   for grep { !$active_urls{$_} } keys %failed_downloads;

    _run_icon_download_gc();
    _log_icon_cache_status();

    # 1. Синхронизация локальных логотипов
    _process_custom_logos($stations, $logo_dir);

    my $banned_icon_urls = _build_banned_icon_urls($stations);
    my ($station_cache_info, $icon_source_cache) = _prescan_station_icons($stations, $logo_dir);

    my @items;
    my $show_subtext = $prefs->get('show_subtext');
    my %stats = (from_cache => 0, queued_download => 0, used_default => 0);

    # 2. Сборка меню
    for my $i (0 .. $#$stations) {
        my $st = $stations->[$i];
        my ($url_md5, $found_ext) = @{ $station_cache_info->[$i] };

        my $final_icon = _resolve_station_icon(
            $st, $url_md5, $found_ext, $logo_dir,
            $icon_source_cache, $banned_icon_urls, \%stats
        );

        push @items, _build_cached_menu_item($st, $final_icon, $show_subtext);
    }

    my @parts;
    push @parts, "From cache=$stats{from_cache}"           if $stats{from_cache} > 0;
    push @parts, "Queued downloads=$stats{queued_download}" if $stats{queued_download} > 0;
    push @parts, "Default icon=$stats{used_default}"        if $stats{used_default} > 0;

    $log->debug(
        sprintf(
            "Cache rebuild complete: %d stations -> %d items%s",
            scalar(@$stations),
            scalar(@items),
            @parts ? ". " . join(', ', @parts) : ""
        )
    );

    $cached_menu_items = \@items;
}

# ============================================================
# RadioBrowserSearch — v2 (Refactored Lifecycle Architecture)
# ============================================================
#Хелперы поиска диапазонов
sub _register_chunk {
    my ($search_term, $start, $len, $req_limit) = @_;
    return unless length($search_term);

    $_chunk_term_seen{$search_term} = time();

    my $chunks = ($_chunk_index{$search_term} ||= []);
    push @$chunks, [$start, $len, $req_limit];
    
    # Защита от утечки памяти при бесконечном скролле:
    # Храним не более 30 последних скачанных чанков для одного поискового запроса.
    shift @$chunks while @$chunks > 30;

    # Защита от утечки памяти на долгом аптайме: ограничиваем число РАЗНЫХ термов.
    if (scalar(keys %_chunk_index) > 50) {
        my @oldest = sort {
            ($_chunk_term_seen{$a} || 0) <=> ($_chunk_term_seen{$b} || 0)
        } keys %_chunk_index;
        for my $t (@oldest[0 .. 14]) {
            delete $_chunk_index{$t};
            delete $_chunk_term_seen{$t};
        }
    }
}

sub _find_covering_chunk {
    my ($search_term, $raw_offset, $lms_limit) = @_;
    $_chunk_term_seen{$search_term} = time() if exists $_chunk_index{$search_term};
    for my $c (@{ $_chunk_index{$search_term} || [] }) {
        my ($start, $len, $req_limit) = @$c;
        
        # Подтверждённый пустой хвост списков
        if ($len == 0) {
            return $start if $raw_offset >= $start;
            next;
        }
        
        next unless $raw_offset >= $start && $raw_offset < $start + $len;
        
        # Покрывает целиком ИЛИ это точно последний неполный чанк
        if (($start + $len) >= ($raw_offset + $lms_limit) || $len < $req_limit) {
            return $start;
        }
    }
    return undef;
}
# ─────────────────────────────────────────────────────────────
# Достает поля запроса без искажения индексов для LMS
# ─────────────────────────────────────────────────────────────
sub _parseSearchArgs {
    my ($args) = @_;

    my $search_term = $args->{search} || $args->{_search} || $args->{query} || '';
    my $raw_offset  = defined $args->{index} ? int($args->{index}) : 0;
    
    # 1. Определяем, сколько просит LMS за один раз (ломтик)
    my $lms_limit = (defined $args->{qty} && int($args->{qty}) > 0) ? int($args->{qty}) : 25;  # от LMS
    
    # 2. ЧАНК: Плагин скачивает за запрос
    my $api_limit = $prefs->get('search_limit') || 100;   # настройка пользователя

    # Если уже скачанный диапазон покрывает запрошенную страницу целиком — используем его.
    # Если нет — качаем ровно с того смещения, которое реально просят, без округления
    # по сетке api_limit/lms_limit — это гарантирует, что страница попадёт в один чанк
    # целиком и не плодит лишних запросов на границах.
    my $existing = _find_covering_chunk($search_term, $raw_offset, $lms_limit);
    my $quantized_offset = defined $existing ? $existing : $raw_offset;

    return ($search_term, $quantized_offset, $api_limit, $raw_offset, $lms_limit);
}
# ─────────────────────────────────────────────────────────────
# Парсит модификаторы (?bitrate #tag @country) и собирает URL.
# ─────────────────────────────────────────────────────────────
sub _buildRadioBrowserUrl {
    my ($search_term, $offset, $limit) = @_;

    my ($min_bitrate, $tag_part, $country_part) = (0, '', '');
    my @name_tokens;

    for my $token (split /\s+/, $search_term) {
        if    ($token =~ /^\?(\d+)$/) { $min_bitrate  = int($1); }
        elsif ($token =~ /^#(.+)$/)   { $tag_part     = lc($1);  }
        elsif ($token =~ /^@([A-Za-z]{2})$/) { $country_part = uc($1);  }
        else  { push @name_tokens, $token if length($token); }
    }
    my $name_part = join(' ', @name_tokens);

    my $url = "https://all.api.radio-browser.info/json/stations/search?"
            . "hidebroken=true&order=clickcount&limit=$limit&offset=$offset";
    $url .= "&name="        . uri_escape_utf8($name_part)    if $name_part;
    $url .= "&tag="         . uri_escape_utf8($tag_part)     if $tag_part;
    $url .= "&countrycode=" . uri_escape_utf8($country_part) if $country_part;
    $url .= "&bitrateMin="  . $min_bitrate                   if $min_bitrate > 0;

	my @filters;
    push @filters, "tag=$tag_part"         if $tag_part;
    push @filters, "country=$country_part" if $country_part;
    push @filters, "bitrate>=$min_bitrate" if $min_bitrate > 0;
    my $filter_str = @filters ? ' [' . join(', ', @filters) . ']' : '';

    return ($url, "'$name_part'$filter_str");
}

# ─────────────────────────────────────────────────────────────
# STATE MODULE: Единая точка контроля для dedupe, cache и stale guard.
# ─────────────────────────────────────────────────────────────
sub _request_lifecycle {
    my ($url, $offset, $raw_offset) = @_;
    $raw_offset //= $offset;

	my $gen;
    my $responded = 0;

    my $lc = {
        url        => $url,
        offset     => $offset,      # квантованный (для API/кэша)
        raw_offset => $raw_offset,  # оригинальный (для ответа LMS)
    };

	$lc->{collapse} = sub {
		my ($cb) = @_;
		if (exists $_search_inflight{$url}) {
			$log->debug("RadioBrowser: [REQUEST] identical search already in flight for position=$offset — attaching to it instead of firing a new one");
			push @{$_search_inflight{$url}}, $cb;
			return 1;
		}
		$_search_inflight{$url} = [$cb];
		$gen = ++$_request_gen{$url};
		$log->debug("RadioBrowser: [REQUEST] #$gen for position=$offset (checking cache first)");
		return 0;
	};

    $lc->{cache_get} = sub {
        return undef unless exists $_api_response_cache{$url};
        my $age = time() - $_api_response_cache{$url}->{timestamp};
        if ($age < 300) {
            $log->debug("RadioBrowser: [CACHE] serving from cache (${age}s old), position=$offset");
            return $_api_response_cache{$url}->{data};
        }
        $log->debug("RadioBrowser: [CACHE] cached page too old (${age}s > 300s), fetching fresh");
        delete $_api_response_cache{$url};
        return undef;
    };

	$lc->{cache_set} = sub {
		my ($data) = @_;
		
		# Мягкое вытеснение (LRU). Никаких полных сбросов при новом поиске!
		if (scalar(keys %_api_response_cache) > 50) {
			$log->debug("RadioBrowser: [CACHE] cache limit reached (50 entries), dropping the 15 oldest");
			
			# Сортируем по времени, чтобы найти самые старые
			my @sorted_keys = sort { 
				$_api_response_cache{$a}->{timestamp} <=> $_api_response_cache{$b}->{timestamp} 
			} keys %_api_response_cache;
			
			# Удаляем 15 самых старых записей
			for my $k (@sorted_keys[0..14]) {
				delete $_api_response_cache{$k};
				# Чистим счетчик генераций по этому URL
				delete $_request_gen{$k} if exists $_request_gen{$k};
				
				# ВАЖНО: $_chunk_index мы здесь НЕ трогаем.
			}
		}
		
		$_api_response_cache{$url} = { data => $data, timestamp => time() };
	};

    $lc->{is_stale} = sub {
        if ($gen != $_request_gen{$url}) {
            $log->debug("RadioBrowser: [REQUEST] discarding outdated response for position=$offset (request #$gen was superseded by request #$_request_gen{$url})");
            return 1;
        }
        return 0;
    };

	$lc->{respond} = sub {
        my ($result) = @_;
        
        # Блокируем дублирующие ответы
        if ($responded++) {
            $log->debug("RadioBrowser: [REQUEST] position=$offset was already answered, skipping duplicate response");
            return;
        }

        # КРИТИЧЕСКИЙ ФИКС: Доверяем вычисленному offset (например, 40) 
        # Если его по какой-то причине нет, только тогда используем базовый $lc->{offset}
        $result->{offset} = defined $result->{offset} ? $result->{offset} : $lc->{raw_offset};

        my $cbs = delete $_search_inflight{$url} // [];
        my $item_count = ref($result->{items}) eq 'ARRAY' ? scalar(@{$result->{items}}) : '?';
        
        # Логируем уже финальный offset, который уйдет в плеер
		$log->debug(sprintf(
            "RadioBrowser: [REQUEST] sending %s item(s) for position=%s to %d waiting caller(s)",
            $item_count, $result->{offset}, scalar(@$cbs)
        ));
        
        # Рассылаем ответ всем ожидающим коллбэкам
        $_->($result) for @$cbs;
    };

    return $lc;
}

# ─────────────────────────────────────────────────────────────
# Единственная функция, дергающая сеть.
# ─────────────────────────────────────────────────────────────
sub _fetchRadioBrowser {
    my ($url, $offset, $on_success, $on_error, $is_retry, $excluded) = @_;
    my $timeout = ($offset == 0) ? 10 : 8;
    $excluded ||= {};

    # 1. Базовый узел "all" всегда участвует первым (это DNS round-robin балансировщик
    #    самого radio-browser.info, он сам выбирает живой узел на своей стороне)
    my ($current_base) = $url =~ m{^(https?://[^/]+)};
    $current_base //= '';
    $excluded->{$current_base} = 1;

    # 2. Второе зеркало — гарантированно НЕ то, что уже падало в этой серии retry
    my @available_mirrors = grep { !$excluded->{$_} } @_RB_MIRRORS;

    # Защита от пустого пула — на случай если все зеркала уже исключены
    if (!@available_mirrors) {
        @available_mirrors = grep { $_ ne $current_base } @_RB_MIRRORS;
    }

    # 3. Выбираем случайное зеркало
    my @endpoints = ($url);
    if (@available_mirrors) {
        my $mirror = $available_mirrors[ int(rand(scalar @available_mirrors)) ];
        $excluded->{$mirror} = 1;
        (my $mirror_url = $url) =~ s{^https?://[^/]+}{$mirror};
        push @endpoints, $mirror_url;
    } else {
        $log->warn("RadioBrowser: [FETCH] No alternate mirror, racing single endpoint.");
    }
	
    my $fired  = 0;
    my $errors = 0;
    my $total  = scalar @endpoints;

    $log->debug("RadioBrowser: [FETCH] Racing offset=$offset timeout=${timeout}s");

	for my $ep (@endpoints) {
        my ($ep_host) = $ep =~ m{^https?://([^/]+)};
        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http = shift;
                return if $fired++; # Блокируем любые последующие действия
                $log->debug("RadioBrowser: [FETCH] Winner: $ep_host offset=$offset");
                $on_success->($http);
            },
            sub {
                my $http = shift;
                
                # ВАЖНО: Если мы уже победили, игнорируем любые ошибки опоздавших запросов
                return if $fired; 

                $errors++;
                $log->debug("RadioBrowser: [FETCH] Failed: $ep_host errors=$errors/$total");
                
				if ($errors >= $total) {
					$fired++;
					if (!$is_retry) {
						$log->debug("RadioBrowser: [FETCH] Both mirrors failed, retry in 700ms offset=$offset excluded=" . join(',', keys %$excluded));
						Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.7, sub {
							_fetchRadioBrowser($url, $offset, $on_success, $on_error, 1, $excluded);
						});
					} else {
						$on_error->($http);
					}
				}
            },
            {
                timeout => $timeout,
            }
        )->get($ep, 'User-Agent' => 'LMS-RadioStationListPlugin/1.8');
    }
}

#обновления зеркал
sub _refresh_mirrors_list {
    # 1. УБИВАЕМ ВСЕ ПРЕДЫДУЩИЕ ТАЙМЕРЫ
    Slim::Utils::Timers::killTimers(undef, \&_refresh_mirrors_list);

    # 2. ЗАЩИТА ОТ ГОНКИ ЗАПРОСОВ (RACE CONDITION)
    if ($_discovery_inflight) {
        $log->debug("RadioBrowser: [DISCOVERY] Already in progress, skipping duplicate call.");
        return;
    }
    $_discovery_inflight = 1;
    
    my $seed_url = $_RB_MIRRORS[ int(rand(scalar @_RB_MIRRORS)) ];
    my $request_url = "$seed_url/json/servers";
    $log->debug("RadioBrowser: [DISCOVERY] Fetching from $seed_url...");
    
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            $_discovery_inflight = 0; # Освобождаем блокировку при успехе
            $mirror_discovery_fail_count = 0; # Сброс счетчика при успехе
			
            my $data = eval { decode_json($http->content) };
            if ($data && ref $data eq 'ARRAY') {
                my %seen = ('https://all.api.radio-browser.info' => 1);
                my @new_mirrors = ('https://all.api.radio-browser.info');
                for my $srv (@$data) {
                    my $name = $srv->{name};
                    next unless $name && $name =~ /^[a-z0-9][a-z0-9.\-]*\.[a-z]{2,}$/i;
                    my $mirror_url = "https://$name";
                    next if $seen{$mirror_url}++;
                    push @new_mirrors, $mirror_url;
                }
                if (scalar(@new_mirrors) > 1) {
                    @_RB_MIRRORS = @new_mirrors;
                    $log->info("RadioBrowser: [DISCOVERY] Updated, " . scalar(@_RB_MIRRORS) . " nodes.");
                } else {
                    $log->warn("RadioBrowser: [DISCOVERY] 0 usable mirrors parsed, keeping current list.");
                }
            } else {
                #$log->warn("RadioBrowser: [DISCOVERY] Unexpected response, retrying in 5 min.");
                #Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 300, \&_refresh_mirrors_list);
				_schedule_retry_with_backoff();
                return;
            }
            Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 12 * 3600, \&_refresh_mirrors_list);
        },
        sub {
            my $err = shift->error || 'Unknown error';
            $_discovery_inflight = 0; # Освобождаем блокировку при ошибке
            
            #$log->warn("RadioBrowser: [DISCOVERY] Failed ($err), retrying in 5 min.");
            #Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 300, \&_refresh_mirrors_list);
			_schedule_retry_with_backoff();
        },
        { timeout => 10 }
    )->get($request_url, 'User-Agent' => 'LMS-RadioStationListPlugin/1.8');
}

sub _schedule_retry_with_backoff {
    $mirror_discovery_fail_count++;

    # Формула: 5 мин * 3^(N-1)
    my $delay_seconds = 300 * (3 ** ($mirror_discovery_fail_count - 1));

    # Ограничиваем максимум 12 часами (43200 сек)
    my $max_delay = 12 * 3600;
    $delay_seconds = $max_delay if $delay_seconds > $max_delay;

    # ЭТОТ ЛОГ — твой «маяк»: ты увидишь рост счётчика и задержку
    $log->info("RadioBrowser: [BACKOFF] Mirror fail count=$mirror_discovery_fail_count, next retry in " . sprintf("%.1f", $delay_seconds/60) . " min");

    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $delay_seconds, \&_refresh_mirrors_list);
}

# ─────────────────────────────────────────────────────────────
# _handleSearchSuccess & _handleSearchError
# ─────────────────────────────────────────────────────────────
sub _handleSearchSuccess {
    my ($http, $lc, $lms_limit, $api_limit, $search_term) = @_;
    my $data = eval { decode_json($http->content) };

    if ($@ || !$data) {
        $log->error("RadioBrowser: [SUCCESS] JSON parse error offset=$lc->{offset}");
        my $result = ($lc->{raw_offset} > 0)
            ? { items => [], total => $lc->{raw_offset} + 1 }
            : { items => [{ name => 'Parse error', type => 'text' }] };
        $lc->{respond}->($result);
        return;
    }

    if ($lc->{is_stale}->()) {
        # Даже устаревший ответ обязан разрулить очередь — иначе
        # $_search_inflight{$url} останется занятым навечно
        $lc->{respond}->({ items => [], offset => $lc->{raw_offset}, total => $lc->{raw_offset} });
        return;
    }

    $lc->{cache_set}->($data);
	# РЕГИСТРАЦИЯ: Запоминаем успешный диапазон в связке с поисковым термом
	_register_chunk($search_term, $lc->{offset}, scalar(@$data), $api_limit);
    $lc->{respond}->(_build_menu_from_raw($data, $lc->{offset}, $lc->{raw_offset}, $lms_limit, $api_limit));
}

# ─────────────────────────────────────────────────────────────
# Скролл (offset > 0) — тихо гасит пагинацию (UX без мусора).
# Первый поиск (offset == 0) — показывает точную причину ошибки.
# ─────────────────────────────────────────────────────────────
sub _handleSearchError {
    my ($http, $lc, $lms_limit) = @_; # ← Теперь принимаем лимит

    $lms_limit //= 25;  # Дефолт на случай, если лимит не долетел
    my $offset = $lc->{offset};
    my $code   = ($http && $http->code)  ? $http->code  : 0;
    my $err    = ($http && $http->error) ? $http->error : 'Unknown';

    $log->warn(sprintf(
        "RadioBrowser: [ERROR] code=%d err='%s' offset=%d",
        $code, $err, $offset
    ));

    # Определяем тип ошибки:
    my $is_api_error = ($code == 502 || $code == 503 || $code == 429) 
                    || ($err =~ /502|503|429/);

    my $msg;
    if ($is_api_error) {
        # Проблемы на стороне серверов Radio-Browser
        $msg = Slim::Utils::Strings::string('RR_ERROR_API') || 'API error, try again';
    } else {
        # Локальные проблемы: упал Wi-Fi, таймаут, проблемы с DNS
        $msg = Slim::Utils::Strings::string('RR_ERROR_NETWORK') || 'Connection error, try again';
    }

    # Добавляем визуальный значок для привлечения внимания
    my $display_text = "⚠️ " . $msg;

    # 1. ЗОЛОТОЕ ПРАВИЛО СКРОЛЛА: 
    # Если это скролл (не первая страница), не блокируем интерфейс
	if ($lc->{raw_offset} > 0) {
        $lc->{respond}->({
            items  => [{
                name => $display_text,
                type => 'text',
                icon => 'html/images/radio.png',   # без icon гридовые скины не рисуют text-item вообще
            }],
            offset => $lc->{raw_offset},
            total  => $lc->{raw_offset} + 1,        # честно: список кончается на этом элементе, не выдумываем +lms_limit вперёд
        });
        return;
    }

    # 2. ОШИБКИ ПЕРВОГО ЗАПРОСА (offset == 0):
    $lc->{respond}->({ items => [{ name => $display_text, type => 'text' }] });
}

# ОРКЕСТРАТОР
sub _searchRadioBrowser {
    my ($client, $callback, $args) = @_;

    my ($search_term, $offset, $api_limit, $raw_offset, $lms_limit) = _parseSearchArgs($args);
    if (!$search_term) {
        $callback->({ items => [] });
        return;
    }

	my ($url, $query_desc) = _buildRadioBrowserUrl($search_term, $offset, $api_limit);
    $log->debug("RadioBrowser: search $query_desc, requested position=$raw_offset"
        . ($offset != $raw_offset ? " (reusing already-downloaded chunk starting at position=$offset)" : "")
        . ", LMS page size=$lms_limit, fetch chunk size=$api_limit");

    my $lc  = _request_lifecycle($url, $offset, $raw_offset);

    return if $lc->{collapse}->($callback);

    my $cached = $lc->{cache_get}->();
    if (defined $cached) {
        $lc->{respond}->(_build_menu_from_raw($cached, $offset, $raw_offset, $lms_limit, $api_limit));
        return;
    }

    eval {
        _fetchRadioBrowser(
            $url, $offset,
            sub {
                _handleSearchSuccess(shift, $lc, $lms_limit, $api_limit, $search_term);
            },
            sub { _handleSearchError(shift, $lc, $lms_limit) },
        );
    };
    if ($@) {
        $log->error("RadioBrowser: [SEARCH] HTTP launch exception: $@");
        my $result = ($raw_offset > 0)
            ? { items => [], total => $raw_offset + 1 }
            : { items => [{ name => Slim::Utils::Strings::string('RR_ERROR_NETWORK'), type => 'text' }] };
        $lc->{respond}->($result);
    }
}

# UI-Шейперы
sub _build_menu_from_raw {
    my ($data, $quantized_offset, $raw_offset, $lms_limit, $api_limit) = @_;
    $raw_offset //= $quantized_offset;
    $api_limit  //= 100;

    my @all_results;
    if (ref $data eq 'ARRAY') {
        for my $s (@$data) {
            my $item = _buildStationListItem($s);
            push @all_results, $item if $item;
        }
    }

    my $all_count   = scalar @all_results;
    my $is_real_end = $all_count < $api_limit;
	my $chunk_end = $quantized_offset + $all_count;  # абсолютный конец скачанных данных

	# --- ВАРИАНТ Б: Обход проблемы Material Skin для первого экрана ---
    # Если запрашивают начало списка, отдаем всё, что пришло из API, 
    # чтобы интерфейс сразу заполнился без лишних скроллов.
    if ($raw_offset == 0) {
        my $total = $is_real_end ? $chunk_end : $chunk_end + 1;
        return {
            items  => $all_count ? \@all_results : [{ name => Slim::Utils::Strings::string('RR_NO_RESULTS'), type => 'text' }],
            offset => 0,
            total  => $total,
        };
    }
    # Нарезка СТРОГО по запросу LMS — без сброса всего чанка для offset=0.
    # Это убирает рассинхрон action_id при кликах из сетки Material Skin.
    my $slice_start = $raw_offset - $quantized_offset;
    my @results;

    if ($slice_start >= 0 && $slice_start < $all_count) {
        my $slice_end = $slice_start + $lms_limit - 1;
        $slice_end = $#all_results if $slice_end > $#all_results;
        @results = @all_results[$slice_start .. $slice_end];
    }

    my $count     = scalar @results;

    # total считаем единообразно для ЛЮБОГО offset, включая 0
    my $total = $is_real_end ? $chunk_end : $chunk_end + 1;

    return {
        items  => $count ? \@results : [{ name => Slim::Utils::Strings::string('RR_NO_RESULTS'), type => 'text' }],
        offset => $raw_offset,
        total  => $total,
    };
}

# _build_cached_menu_item: Чистый шейпер элемента меню LMS
sub _build_cached_menu_item {
    my ($st, $final_icon, $show_subtext) = @_;

    my $url  = $st->{url}  // '';
    my $name = $st->{name} // '';

	my $item = {
		name        => $name,
		type        => 'audio',
		url         => $url,
		on_select   => 'play',
		line1       => $name,
		icon        => $final_icon,
		image       => $final_icon,
		cover       => $final_icon,
		artwork_url => $final_icon,
		itemActions => {
			info => {
				command     => ['radiostationlistinfo', 'items'],
				fixedParams => {
					url     => $url,
					title   => $name,
					genre   => $st->{tags},
					country => $st->{country},
					ccode   => $st->{countrycode} || '',
					codec   => $st->{codec},
					bitrate => $st->{bitrate},
					homepage => $st->{homepage} // '',
                    uuid     => $st->{uuid} // '',
				},
			},
		},
	};

    if ($show_subtext) {
        my @meta;
        my $tech_info = join(' ', grep $_, uc($st->{codec} || ''), ($st->{bitrate} ? "$st->{bitrate}k" : ''));
        
        push @meta, $tech_info   if $tech_info =~ /\S/;
        push @meta, $st->{tags}  if $st->{tags}    && $st->{tags}    =~ /\S/;
        push @meta, $st->{country} if $st->{country} && $st->{country} =~ /\S/;
        
        $item->{line2} = join(' • ', @meta) || $url;
    }

    return $item;
}

# Форматирует одну станцию из сырых данных.
sub _buildStationListItem {
    my ($s) = @_;

    my $station_url  = $s->{url_resolved} || $s->{url};
    my $station_name = $s->{name} // '';
	$station_name =~ s/^\s+|\s+$//g;
    my $station_icon = $s->{favicon} || '';

	# 1. Проверяем валидность: отсекаем пробелы, кириллицу без %XX, проблемные хосты
	if (!$station_icon 
		|| $station_icon !~ m{^https?://[\x21-\x7E]+$}i 
		|| $station_icon =~ /(firebasestorage\.googleapis\.com|googleusercontent\.com)/i) {
		
		$station_icon = 'html/images/radio.png'; # Ставим наш дефолт
	} 
	# 2. Если ссылка прошла проверку (она валидная), делаем апгрейд http -> https
	else {
		$station_icon =~ s{^http://}{https://}i;
	}

    my $bitrate = $s->{bitrate} || 0;
    $bitrate = int($bitrate / 1000) if $bitrate > 9999;
    my $codec   = uc($s->{codec} || '');
	if ($codec =~ /UNKNOWN/ || $codec eq '') {
        $codec = '';
    }
    my $tags    = $s->{tags}    || '';
    my $ccode   = $s->{countrycode} || '';
    my $country = $s->{country} || '';

    my $badge = !$bitrate       ? ''
              : $bitrate >= 256 ? "🟢 "
              : $bitrate >= 192 ? "⚪ "
              : $bitrate >= 128 ? "🟡 "
              :                   "🔴 ";
  
    my $homepage = $s->{homepage} // '';
    $homepage =~ s/^\s+|\s+$//g;
    my $uuid = $s->{stationuuid} // '';
	
	# === ЛОКАЛЬНАЯ ЗАМЕНА: Сборка подписи line2 ===
    my @meta_parts;

    # 1. Аудио-информация: строгий гард от "0k" и пустых строк
    my $audio_info = '';
    if ($bitrate) {
        $audio_info = $badge . ($codec ? "$codec " : "") . "${bitrate}k";
    } elsif ($codec) {
        $audio_info = $codec;
    }
    push @meta_parts, $audio_info if $audio_info =~ /\S/;

    # 2. Защита от пробелов бэкенда: триммим края, чтобы точка прижималась плотно
    $tags    =~ s/^\s+|\s+$//g;
	$tags = substr($tags, 0, 117) . '...' if length($tags) > 120;
    $country =~ s/^\s+|\s+$//g;

    # 3. В массив идут только гарантированно заполненные поля
    push @meta_parts, $tags    if $tags    =~ /\S/;
    push @meta_parts, $country if $country =~ /\S/;

    # 4. Безопасный join: чистый результат без висящих разделителей
    my $meta = join(' · ', @meta_parts);
    # ===============================================

    return {
        name  		=> $station_name,
        line1 		=> $station_name,
        line2 		=> $meta,
        icon  		=> $station_icon,
        image 		=> $station_icon,
        type  => 'directory',
		url   => sub {
            my ($cl, $cb, $a) = @_;

            $log->debug(sprintf("RadioBrowser: [CLICK] ENTER station '%s'", $station_name // ''));

            eval {
                _stationActionMenu(
                    $cl, $cb, $a,
                    $station_name, $station_url, $station_icon,
                    $bitrate, $codec, $tags, $ccode, $country, $homepage, $uuid
                );
            };
            if ($@) {
                $log->error(sprintf(
                    "RadioBrowser: [BUILD-ITEM] closure error '%s': %s",
                    $station_name, $@
                ));
                $cb->({ items => [{ name => Slim::Utils::Strings::string('RR_ERROR_NETWORK') || 'Error', type => 'text' }] });
            }
        },
    };
}

# ─────────────────────────────────────────────────────────────
# ACTION & PREFS
# ─────────────────────────────────────────────────────────────
sub _stationActionMenu {
    my ($client, $callback, $args, $s_name, $s_url, $s_icon, $s_bitrate, $s_codec, $s_tags, $s_ccode, $s_country, $s_homepage, $s_uuid) = @_;

    # Защита от гигантских спам-тегов, чтобы не перегружать кэш и UI
    if (defined $s_tags && length($s_tags) > 120) {
        $s_tags = substr($s_tags, 0, 117) . '...';
    }

    $callback->({
        items => [
			{
				name        => $s_name,
				type        => 'audio',
				url         => $s_url,
				on_select   => 'play',
				icon        => $s_icon,
				image       => $s_icon,
				itemActions => {
					info => {
						command     => ['radiostationlistinfo', 'items'],
						fixedParams => {
							url     => $s_url,
							title   => $s_name,
							genre   => $s_tags,
							country => $s_country,
							ccode   => $s_ccode,
							codec   => $s_codec,
							bitrate => $s_bitrate,
							homepage => $s_homepage,
                            uuid     => $s_uuid,
						},
					},
				},
			},
            {
                name => Slim::Utils::Strings::string('RR_ADD_FAV') || 'Add to my stations',
                type => 'directory',
                icon => 'html/images/favorites.png',
                url  => sub {
                    my ($cl, $cb) = @_;
                    _addStationToPrefs($cb, $s_name, $s_url, $s_icon, $s_bitrate, $s_codec, $s_tags, $s_ccode, $s_country, $s_homepage, $s_uuid);
                },
            },
        ],
        nocache => 1,
    });
}

sub _addStationToPrefs {
    my ($cb, $name, $url, $icon, $bitrate, $codec, $tags, $ccode, $country, $homepage, $uuid) = @_;
    # Убираем пробелы и табы в начале/конце имени от Radio Browser
    $name =~ s/^\s+|\s+$//g if defined $name;

    # Тот же regex, что и при ручном вводе в настройках — Radio Browser может
    # отдать "грязный" non-ASCII URL, который ломает LMS DbCache.
    unless ($url && $url =~ m{^https?://[\x21-\x7E]+$}i) {
        $log->warn("RadioBrowser: [ACTION] Rejected '$name' — invalid stream URL: " . ($url // ''));
        $cb->({ items => [{ name => Slim::Utils::Strings::string('RR_ERROR_URL') || 'Invalid stream URL', type => 'text' }] });
        return;
    }

    my $stations = [ @{ $prefs->get('stations') || [] } ];

    if (grep { lc($_->{url}) eq lc($url) } @$stations) {
        $cb->({ items => [{ name => Slim::Utils::Strings::string('RR_ALREADY_ADDED') || 'Already in my stations', type => 'text' }] });
        return;
    }

    push @$stations, {
        name        => $name,
        url         => $url,
        icon        => ($icon && $icon !~ m{^html/images/}) ? $icon : '',
        bitrate     => $bitrate ? int($bitrate) : 0,
        codec       => $codec || '',
        tags        => $tags,
        countrycode => $ccode,
        country     => $country,
		homepage    => $homepage,
        uuid        => $uuid,
    };

    $prefs->set('stations', $stations);
    _trigger_cache_update();

    $log->info("RadioBrowser: [ACTION] Added '$name'");
    $cb->({ items => [{ name => Slim::Utils::Strings::string('RR_ADDED') || 'Added!', type => 'text' }] });
}

sub _onPlayEvent {
	my $request = shift;
	my $client  = $request->client or return;
	my $song    = $client->playingSong() or return;
	my $track   = $song->currentTrack() or return;
	
	my $url     = $track->url    or return;
	my $bitrate = $track->bitrate || 0;
	my $ct      = $track->content_type || '';

	$log->debug("_onPlayEvent — url=[$url] bitrate=[$bitrate] ct=[$ct]");

	# Если битрейт еще не определился (0), запускаем отложенную проверку
	if (!$bitrate) {
		# Сохраняем кодек сразу, если контент-тип уже известен (например, mp3 из ссылки)
		_applyTrackMeta($url, 0, $ct) if $ct;

		# Заводим таймер, только если для этого конкретного URL его еще нет
		my $timer_key = $client->id . '|' . $url;
        unless ($pending_timers{$timer_key}) {
            $pending_timers{$timer_key} = 1;
            
            Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 5, sub {
                my $cl = shift;
                delete $pending_timers{$timer_key};
                _onPlayEvent_delayed($cl, $url);
            });
        }
		return;
	}
	
	_applyTrackMeta($url, $bitrate, $ct);
}

sub _onPlayEvent_delayed {
	my ($client, $expected_url) = @_;
	return unless $client && $expected_url;

	my $song  = $client->playingSong() or return;
	my $track = $song->currentTrack()  or return;
	
	my $current_url = $track->url      or return;
	
	# КРИТИЧЕСКАЯ ПРОВЕРКА: Если пользователь уже переключил станцию за эти 5 секунд, 
	# мы ничего не делаем, чтобы не повредить метаданные новой станции.
	if ($current_url ne $expected_url) {
		$log->debug("_onPlayEvent_delayed — URL changed during bounce, skipping. Expected: [$expected_url], Got: [$current_url]");
		return;
	}
	
	my $bitrate = $track->bitrate || 0;
	my $ct      = $track->content_type || '';
	
	$log->debug("_onPlayEvent_delayed — url=[$current_url] bitrate=[$bitrate] ct=[$ct]");
	
	# Даже если битрейт остался 0, имеет смысл обновить метаданные (мог прийти хотя бы контент-тип)
	_applyTrackMeta($current_url, $bitrate, $ct);
}

sub _applyTrackMeta {
	my ($url, $bitrate, $ct) = @_;

	# Нормализуем битрейт
	$bitrate = int($bitrate / 1000) if $bitrate > 9999;
	return unless $bitrate > 0 || $ct;

	# Определяем кодек
	$ct ||= '';
	my $codec = $ct =~ /aacp/i           ? 'AAC+'
			  : $ct =~ /aac|m4a|mp4/i    ? 'AAC'
			  : $ct =~ /mpeg|mp3/i       ? 'MP3'
			  : $ct =~ /ogg|opus/i       ? 'OGG'
			  : $ct =~ /flac/i           ? 'FLAC'
			  :                            '-';
	$log->debug("_applyTrackMeta called — url=[$url] bitrate=[$bitrate] ct=[$ct] codec=[$codec]");
	my $stations = $prefs->get('stations') || [];
	my $changed  = 0;
	
	for my $st (@$stations) {
		if ($st->{url} eq $url) {
			my $b_changed = $bitrate > 0 && ($st->{bitrate} || 0) != $bitrate;
			my $c_changed = $codec && ($st->{codec} || '') ne $codec;
			
			if ($b_changed || $c_changed) {
				$st->{bitrate} = $bitrate if $b_changed;
				$st->{codec}   = $codec   if $codec && $c_changed;
				$changed = 1;
			}
		}
	}
	# Сохраняем изменения только если реально что-то обновилось
	if ($changed) {
		$prefs->set('stations', [ @$stations ]);
		_trigger_cache_update();
		$log->info("Meta updated for '$url' → " . ($codec || 'Unknown') . " | $bitrate kbps");
	}
}

sub _stationInfoCliQuery {
    my $request = shift;

    my $client  = $request->client;
    my $url     = $request->getParam('url');
    my $title   = $request->getParam('title');
    my $genre   = $request->getParam('genre');
    my $country = $request->getParam('country');
    my $ccode   = $request->getParam('ccode');
    my $codec   = $request->getParam('codec');
    my $bitrate = $request->getParam('bitrate');
    my $homepage= $request->getParam('homepage');
    my $uuid    = $request->getParam('uuid');

    my $nameLabel    = Slim::Utils::Strings::string('RR_INFO_NAME');
    my $genreLabel   = Slim::Utils::Strings::string('RR_INFO_GENRE');
    my $countryLabel = Slim::Utils::Strings::string('RR_INFO_COUNTRY');
    my $codecLabel   = Slim::Utils::Strings::string('RR_CODEC');
    my $bitrateLabel = Slim::Utils::Strings::string('RR_BITRATE');
    my $homeLabel    = Slim::Utils::Strings::string('RR_INFO_HOMEPAGE') || 'Website';

    my $items = [
        { type => 'text', name => $nameLabel . ': ' . ($title || $url || 'Unknown') },
        { type => 'text', name => 'URL' . ': ' . Slim::Utils::Misc::unescape($url || '') },
    ];

    push @$items, { type => 'text', name => $genreLabel . ': ' . $genre } if $genre && $genre =~ /\S/;

    if ($country && $country =~ /\S/) {
        my $countryVal = $ccode ? "$country ($ccode)" : $country;
        push @$items, { type => 'text', name => $countryLabel . ': ' . $countryVal };
    }

    push @$items, { type => 'text', name => $codecLabel . ': ' . uc($codec) } if $codec && $codec =~ /\S/;
    push @$items, { type => 'text', name => $bitrateLabel . ': ' . "${bitrate} kbps" } if $bitrate;
    
	# homepage/uuid приходят из Radio Browser — не доверенный источник,
    # без экранирования можно разорвать href="" и внедрить произвольный HTML
    my $esc_html = sub {
        my ($s) = @_;
        $s =~ s/&/&amp;/g;
        $s =~ s/</&lt;/g;
        $s =~ s/>/&gt;/g;
        $s =~ s/"/&quot;/g;
        return $s;
    };
	# Раньше не было own field url — ссылка была просто текстом внутри name, некликабельна вообще
	if ($homepage && $homepage =~ m{^https?://}i) {
        my $safe_url = $esc_html->($homepage);
        push @$items, {
            type => 'text',
            name => $homeLabel . ': <a href="' . $safe_url . '" target="_blank" >' . $safe_url . '</a>',
        };
    }
    if ($uuid && $uuid =~ /^[a-f0-9-]+$/i) {
        my $rb_url = 'https://www.radio-browser.info/history/' . $uuid;
        push @$items, {
            type => 'text',
            name => 'Radio-Browser URL: <a href="' . $rb_url . '" target="_blank" >' . $rb_url . '</a>',
        };
    }
	
    my $feed = { type => 'opml', name => $title || '', items => $items };

    Slim::Control::XMLBrowser::cliQuery('radiostationlistinfo', $feed, $request);
}

sub _serveWebpPreview {
	my ($client, $response) = @_;
	my $path = $response->request->uri->path;
	my ($hash) = $path =~ m{webp-preview/([a-f0-9]{32})}i;

	$log->debug("[WEBP-RAW] Request path: $path | Hash: " . ($hash // 'none'));

	if ($hash) {
		my $filepath = File::Spec->catfile($plugin_dir, 'HTML', 'EN', 'plugins', 'RadioStationList', 'html', 'RadioLogo', "$hash.webp");

		if (-f $filepath && open(my $fh, '<:raw', $filepath)) {
			local $/;
			my $content = <$fh>;
			close($fh);

			$response->code(200);
			$response->content_type('image/webp');
			$response->header('Cache-Control' => 'max-age=86400, public');
			$response->content_length(length($content));

			Slim::Web::HTTP::addHTTPResponse($client, $response, \$content);
			return;
		}
		$log->warn("[WEBP-RAW] File not found on disk: $filepath");
	} else {
		$log->warn("[WEBP-RAW] Invalid or missing hash in path: $path");
	}

	$response->code(404);
	my $err = 'Image not found';
	$response->content_length(length($err));
	Slim::Web::HTTP::addHTTPResponse($client, $response, \$err);
}

1;