package Plugins::RadioStationList::Settings;

use strict;
use warnings;
use utf8;
use base qw(Slim::Web::Settings);

use Encode qw(encode_utf8 decode_utf8);
use Digest::MD5 qw(md5_hex);
use File::Spec;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::OSDetect;
use JSON::XS qw(decode_json encode_json);

my $prefs = preferences('plugin.radiostationlist');
my $log   = logger('plugin.radiostationlist');

sub new {
	my $class  = shift;
	my $plugin = shift;
	$class->SUPER::new($plugin);
}

sub name     { 'RADIO_STATION_LIST' }
sub category { 'plugins' }
sub page     { 'plugins/RadioStationList/settings/basic.html' }

sub handler {
	my ($class, $client, $params) = @_;

	my $logo_dir = File::Spec->catdir($Plugins::RadioStationList::Plugin::plugin_dir, 'HTML', 'EN', 'plugins', 'RadioStationList', 'html', 'RadioLogo');
	my $custom_logo_dir_pref = $prefs->get('custom_logo_dir') || '';
	
	my $needs_cache_update = 0;
	
	# 1. Проверяем изменение пути к кастомным логотипам
	if (exists $params->{custom_logo_dir}) {
		if (($prefs->get('custom_logo_dir') // '') ne $params->{custom_logo_dir}) {
			$prefs->set('custom_logo_dir', $params->{custom_logo_dir});
			$custom_logo_dir_pref = $params->{custom_logo_dir};
			$needs_cache_update = 1; # Пересчитываем кэш, чтобы скопировать файлы из нового места
		}
	}
	
	# 2. Проверяем изменение флага подтекста (show_subtext)
	if (exists $params->{pref_show_subtext}) {
		my $new_subtext = $params->{pref_show_subtext} ? 1 : 0;
		if (($prefs->get('show_subtext') // 0) != $new_subtext) {
			$prefs->set('show_subtext', $new_subtext);
			$needs_cache_update = 1; # <-- Гарантирует моментальное обновление меню плеера
		}
	}
	# 2b. Проверяем изменение флага прокси иконок (use_icon_proxy)
	if (exists $params->{pref_use_icon_proxy}) {
		my $new_proxy = $params->{pref_use_icon_proxy} ? 1 : 0;
		if (($prefs->get('use_icon_proxy') // 0) != $new_proxy) {
			$prefs->set('use_icon_proxy', $new_proxy);
		}
	}
	# 2c. Проверяем изменение флага поддержки WebP (allow_webp_playlist)
	if (exists $params->{pref_allow_webp_playlist}) {
		my $new_webp = $params->{pref_allow_webp_playlist} ? 1 : 0;
		if (($prefs->get('allow_webp_playlist') // 0) != $new_webp) {
			$prefs->set('allow_webp_playlist', $new_webp);
			$needs_cache_update = 1; # Пересобираем кэш плейлиста, чтобы показать/скрыть WebP иконки
		}
	}
	# Ручной сброс ошибок скачивания иконок по кнопке
	my $force_logo_rescan = 0;

	# Ручной сброс ошибок скачивания иконок по кнопке — заодно форсирует
	# полный пересчёт кастомных логотипов в обход mtime/size кэша (см. ниже)
	if ($params->{reset_icon_errors}) {
			Plugins::RadioStationList::Plugin::_reset_icon_error_state();
			$log->debug("Manual reset of icon errors triggered from UI (also forcing full custom logo rescan)");
			$needs_cache_update = 1;
			$force_logo_rescan = 1;
		}
		
	# 3. Лимит поиска
	if (defined $params->{search_limit}) {
		my $new_limit = int($params->{search_limit}) || 100;
		# Жестко держим в границах твоего дропдауна (50 - 250)
		$new_limit = 50  if $new_limit < 50;
		$new_limit = 250 if $new_limit > 250;
		$prefs->set('search_limit', $new_limit);
	}
	
	# 4. Обработка списка станций (смарт-дифф, GC)
	my $stations_changed = $class->_handle_stations_update($params, $logo_dir);
	$needs_cache_update ||= $stations_changed;

	# ПОДГОТОВКА ДАННЫХ ДЛЯ ШАБЛОНА
	# СИНХРОННАЯ ПРОВЕРКА ЛОКАЛЬНЫХ ПАПОК: 
	# Чтобы интерфейс обновлялся мгновенно по кнопке Сохранить, перекладываем файлы до рендера.
	# Учитываем результат: замена файла кастомного лого (без изменения имени/URL станции)
	# тоже обязана пересобрать кэш плеера, иначе плейлист покажет старую иконку.
	my $logos_changed = eval { Plugins::RadioStationList::Plugin::_process_custom_logos($prefs->get('stations') || [], $logo_dir, $force_logo_rescan); };
	if ($@) {
		$log->error("Failed to process custom logos: $@");
		$logos_changed = 0;
	}
	if ($logos_changed) {
		$log->debug("[CUSTOM-LOGO] handler: $logos_changed file(s) changed on disk, forcing playlist cache rebuild");
	}
	$needs_cache_update ||= $logos_changed;

	if ($needs_cache_update) { Plugins::RadioStationList::Plugin::_trigger_cache_update(); }

	my ($disp_stations, $disp_json) = $class->_prepare_display_stations($logo_dir);
	$params->{stations}      = $disp_stations;
	$params->{stations_json} = $disp_json;
	
	$params->{custom_logo_dir} = $custom_logo_dir_pref; 
	
	$params->{default_logo_dir} = File::Spec->catdir((Slim::Utils::OSDetect::dirsFor('cache'))[0], 'MyRadioLogo');
	
	$params->{pref_show_subtext} = $prefs->get('show_subtext');
	
	$params->{search_limit} = $prefs->get('search_limit') || 100;
	
	$params->{pref_use_icon_proxy} = $prefs->get('use_icon_proxy') // 0;
	
	$params->{pref_allow_webp_playlist} = $prefs->get('allow_webp_playlist') // 0;
	
	return $class->SUPER::handler($client, $params);
}

# Утилита: безопасно генерирует MD5 хэш для URL потока
sub _get_url_hash {
    my ($class, $url) = @_;
    return Plugins::RadioStationList::Plugin::_get_url_hash($url);
}

# Обработка списка станций (тяжелый JSON)
sub _handle_stations_update {
	my ($class, $params, $logo_dir) = @_;
	my $needs_update = 0;

	if (defined $params->{stations_json}) {
		my $json_bytes = encode_utf8($params->{stations_json});
		my $stations = eval { decode_json($json_bytes) };
		
		if ($@) {
			$log->error("Failed to parse stations JSON from browser. Error: $@");
		}
		
		if (!$@ && ref $stations eq 'ARRAY') {
			my $old_stations_ref = $prefs->get('stations') || [];

			# === ВАЛИДАЦИЯ URL ПОТОКА (защита от Wide character / Bad dispatch) ===
			# "Сырой" non-ASCII или вообще не-URI в поле url ломает ядро LMS на уровне
			# DbCache (Wide character in subroutine entry) и валит JSON-RPC выдачу
			# топ-левел меню плагина для ВСЕХ клиентов сразу. Проверяем здесь
			# независимо от клиента — форма на странице могла быть обойдена.
			my $has_invalid = 0;
			foreach my $st (@$stations) {
				if (($st->{url} // '') !~ /^https?:\/\/[\x21-\x7E]+$/i) {
					$log->error("Rejected update: station '" . ($st->{name} // '') . "' has invalid URL: " . ($st->{url} // '<empty>'));
					$has_invalid = 1;
				}
			}

			if ($has_invalid) {
				# Прерываем сохранение ВСЕГО списка, чтобы защитить настройки от урезания
				return $needs_update; 
			}
			
			# === ДЕДУПЛИКАЦИЯ ПО URL (финальная защита, UI-проверка только клиентская) ===
			my %seen_url;
			$stations = [ grep {
				my $key = lc($_->{url} // '');
				!$seen_url{$key}++;
			} @$stations ];
			
			# === СМАРТ-АНАЛИЗ ИЗМЕНЕНИЙ СПИСКА СТАНЦИЙ ===
			# Сравниваем глубокую идентичность массивов, чтобы избежать ложных перезапусков кэша
			my $is_identical = (scalar(@$stations) == scalar(@$old_stations_ref)) ? 1 : 0;
			if ($is_identical) {
				for my $i (0 .. $#$stations) {
					my $s = $stations->[$i];
					my $o = $old_stations_ref->[$i];
					if (($s->{url}//'') ne ($o->{url}//'') || 
						($s->{name}//'') ne ($o->{name}//'') || 
						($s->{icon}//'') ne ($o->{icon}//'') ||
						($s->{bitrate}//0) != ($o->{bitrate}//0) ||
						($s->{codec}//'') ne ($o->{codec}//'') ||
						($s->{tags}//'') ne ($o->{tags}//'') ||
						($s->{country}//'') ne ($o->{country}//'') ||
						($s->{countrycode}//'') ne ($o->{countrycode}//'')) {
						$is_identical = 0;
						last;
					}
				}
			}

			# Взводим обновление кэша только если структура, данные или порядок реально изменились.
			# Если список идентичен — выходим сразу и не трогаем диск/папку с логотипами.
			if (!$is_identical) {
				$needs_update = 1;
			} else {
				return $needs_update; # 0
			}

			# === Обработка изменений иконок и очистка кэша ошибок ===
			
			# 1. Вычисляем "коллективный" старый логотип (с защитой дублей)
			# Приоритет отдаем непустому значению, чтобы дубликат с логотипом не затирался дубликатом без логотипа
			my %old_url_icons;
			for my $old (@$old_stations_ref) {
				my $u = $old->{url} // '';
				if ($u) {
					if (!$old_url_icons{$u}) {
						$old_url_icons{$u} = $old->{icon} // ''; 
					}
				}
			}

			# 2. Вычисляем новый "коллективный" логотип для каждого уникального URL
			my %new_url_icons;
			for my $st (@$stations) {
				my $u = $st->{url} // '';
				if ($u) {
					if (!$new_url_icons{$u}) {
						$new_url_icons{$u} = $st->{icon} // '';
					}
				}
			}

			# 2b. ДЕТЕКЦИЯ ЧИСТОГО ПЕРЕИМЕНОВАНИЯ STREAM-URL (та же станция, тот же icon).
			# По индексу строки — как и в сравнении $is_identical выше. Если имя и иконка
			# не менялись, а изменился только URL — это правка адреса потока, а не новая
			# станция с иконкой "из ниоткуда". Без этого шага цикл 3 ниже видит новый URL
			# с пустым old_icon и считает, что иконка "появилась" → лишний delete+redownload
			# уже скачанного файла.
			my $last_i = ($#$stations < $#$old_stations_ref) ? $#$stations : $#$old_stations_ref;
			for my $i (0 .. $last_i) {
				my $s = $stations->[$i];
				my $o = $old_stations_ref->[$i];
				next unless $o->{url} && $s->{url} && $o->{url} ne $s->{url};
				next unless ($s->{name}//'') eq ($o->{name}//'') && ($s->{icon}//'') eq ($o->{icon}//'');

				# Доп. защита от перестановки двух станций с одинаковыми name/icon
				# (например, разные битрейты одного эфира): если старый url всё ещё
				# где-то есть в новом списке, или новый url уже был где-то в старом —
				# это не рено, а просто перестановка, миграцию кэша не делаем.
				next if grep { ($_->{url} // '') eq $o->{url} } @$stations;
				next if grep { ($_->{url} // '') eq $s->{url} } @$old_stations_ref;

				my ($old_u, $new_u) = ($o->{url}, $s->{url});

				# "Наследуем" старую иконку под новым ключом — цикл 3 увидит old_icon == new_icon
				# и не поднимет спорный лог/очистку для этого URL.
				$old_url_icons{$new_u} = $old_url_icons{$old_u} if exists $old_url_icons{$old_u};

				# ПРИОРИТЕТ КАСТОМНОГО ЛОГО: если старый URL прямо сейчас обслуживается
				# локальным файлом — переносить физически нечего (там не remote-кэш, а
				# копия из папки кастомных лого). _process_custom_logos сама переподхватит
				# новый URL по имени станции чуть ниже в handler(). Просто выходим.
				next if $Plugins::RadioStationList::Plugin::custom_logo_active_urls{$old_u};

				my $old_hash = $class->_get_url_hash($old_u);
				my $new_hash = $class->_get_url_hash($new_u);
				for my $ext (qw(png jpg jpeg gif ico svg webp)) {
					my $src = File::Spec->catfile($logo_dir, "$old_hash.$ext");
					next unless -e $src;
					my $dst = File::Spec->catfile($logo_dir, "$new_hash.$ext");
					if (rename($src, $dst)) {
						$log->debug("[URL-MIGRATE] '$old_hash.$ext' -> '$new_hash.$ext' (stream URL renamed, icon unchanged)");
					} else {
						$log->warn("[URL-MIGRATE] Failed to move '$old_hash.$ext' -> '$new_hash.$ext': $!");
					}
				}
			}

			# 3. Синхронизируем изменения: сбрасываем баны и ЖЕСТКО вычищаем старый кэш при смене ссылки
			for my $url (keys %new_url_icons) {
				my $old_icon = $old_url_icons{$url} // '';
				my $new_icon = $new_url_icons{$url} // '';
				
				if ($old_icon ne $new_icon) {
					$log->info("URL change detected for '$url'. Icon updated: [$old_icon] -> [$new_icon]");

					delete $Plugins::RadioStationList::Plugin::permanent_failures{$url};
					delete $Plugins::RadioStationList::Plugin::failed_downloads{$url};
					my $change_hash = $class->_get_url_hash($url);
					delete $Plugins::RadioStationList::Plugin::downloading{$change_hash};
					
					# Eсли станция прямо сейчас обслуживается локальным файлом —
					# он приоритетнее icon-поля, кэш трогать не нужно
					if (!$Plugins::RadioStationList::Plugin::custom_logo_active_urls{$url}) {
						# АДРЕСНАЯ ОЧИСТКА: Так как ссылка изменилась, старый файл кэша на диске больше не валиден.
						# Удаляем его превентивно прямо здесь, чтобы не плодить зомби-расширения (.png/.jpg)
						if (-d $logo_dir) {
							for my $ext (qw(png jpg jpeg gif ico svg webp)) {
								my $old_file_path = File::Spec->catfile($logo_dir, "$change_hash.$ext");
								if (-e $old_file_path) {
									unlink $old_file_path;
									$log->debug("Cleared old cache file due to icon update: $change_hash.$ext");
								}
							}
						}
					}
				}
			}
			
			# === ОЧИСТКА КЭША ПРИ ПЕРЕИМЕНОВАНИИ СТАНЦИИ ===
			if (-d $logo_dir) {
				my %old_names;
				for my $old (@$old_stations_ref) {
					my $u = $old->{url} // '';
					$old_names{$u} = $old->{name} // '' if $u;
				}

				my $custom_dir = $prefs->get('custom_logo_dir') || File::Spec->catdir($Plugins::RadioStationList::Plugin::plugin_dir, 'MyRadioLogo');
				my %available_custom_logos;
				if (opendir(my $dh, $custom_dir)) {
					while (my $file = readdir($dh)) {
						next if $file =~ /^\./;
						my $decoded_file = eval { decode_utf8($file, 1) } // $file;
						if ($decoded_file =~ /^(.*)\.(png|jpg|jpeg|gif|ico|svg)$/i) {
							$available_custom_logos{lc($1)} = 1;
						}
					}
					closedir($dh);
				}

				for my $st (@$stations) {
					my $u = $st->{url} // '';
					next unless $u;
					my $new_name = $st->{name} // '';
					my $old_name = $old_names{$u} // '';
					next if !$old_name || $new_name eq $old_name;
					next unless $Plugins::RadioStationList::Plugin::custom_logo_active_urls{$u};
					# Если для НОВОГО имени есть кастомный файл — не чистим руками: _process_custom_logos
					# сам перезапишет этот хэш (размер/расширение почти наверняка другие). Ручная чистка
					# нужна только когда совпадения для нового имени нет — тогда сам процесс никогда
					# не тронет этот хэш, и старый файл иначе остался бы висеть вечно.
					next if $available_custom_logos{lc($new_name)};

					my $hash = $class->_get_url_hash($u);
					for my $ext (qw(png jpg jpeg gif ico svg webp)) {
						my $path = File::Spec->catfile($logo_dir, "$hash.$ext");
						if (-e $path) {
							unlink $path;
							$log->debug("Cleared cache '$hash.$ext' for rename '$old_name' -> '$new_name'");
						}
					}
				}
			}
			# --- ЗАЩИТА ОТ ГОНКИ МЕТАДАННЫХ ---
			# Браузер присылает старый снимок списка. Если в фоне плеер обновил битрейт/кодек,
			# нам нужно перенести их в новый массив перед сохранением, сопоставив по URL.
			my %live_meta;
			for my $old (@$old_stations_ref) {
				my $u = $old->{url} // '';
				$live_meta{$u} = { b => $old->{bitrate}, c => $old->{codec} } if $u;
			}
			
			# Вычищаем временные UI-флаги и переносим актуальные bitrate/codec,
			# которые плеер мог обновить в фоне после загрузки страницы браузером
			for my $st (@$stations) { 
				delete $st->{display_icon}; 
				delete $st->{icon_state};
				delete $st->{icon_source};
				delete $st->{_icon_pending};

				my $u = $st->{url} // '';
				if ($u && $live_meta{$u}) {
					$st->{bitrate} = $live_meta{$u}{b} if $live_meta{$u}{b};
					$st->{codec}   = $live_meta{$u}{c} if $live_meta{$u}{c};
				}
			}

			# Сохраняем новый список в преференсы и принудительно сбрасываем на диск
			$prefs->set('stations', $stations);
			$prefs->save();
			
			# --- ОЧИСТКА ГЛОБАЛЬНЫХ ОШИБОК ДЛЯ УДАЛЕННЫХ СТАНЦИЙ ---
			my %active_urls      = map { $_->{url}  => 1 } grep { $_->{url}  } @$stations;
			for my $hash_ref (\%Plugins::RadioStationList::Plugin::permanent_failures, 
			                  \%Plugins::RadioStationList::Plugin::failed_downloads) {
				for my $k (keys %$hash_ref) {
					delete $hash_ref->{$k} unless $active_urls{$k};
				}
			}
			# TTL вместо "активна/не активна прямо сейчас": частая правка одной и той же
			# станции (URL/иконка туда-сюда) раньше стирала счётчик страйков в момент,
			# когда иконка временно оказывалась не привязана ни к одной станции — из-за
			# этого лимит в 2 страйка никогда не срабатывал, и плагин бесконечно долбил
			# один и тот же мёртвый URL. Теперь чистим только то, к чему реально не
			# обращались последние 10 минут, независимо от текущей привязки к станции.
			my $ICON_RETRY_TTL = 600; # 10 минут
			my $icon_gc = 0;
			my $now = time();
			for my $k (keys %Plugins::RadioStationList::Plugin::icon_retry_attempts) {
				my $last = $Plugins::RadioStationList::Plugin::icon_retry_last_attempt{$k} || 0;
				next if ($now - $last) < $ICON_RETRY_TTL;
				delete $Plugins::RadioStationList::Plugin::icon_retry_attempts{$k};
				delete $Plugins::RadioStationList::Plugin::icon_retry_last_attempt{$k};
				$icon_gc++;
			}
			$log->debug("[DEDUP-GC] Removed $icon_gc stale icon_retry_attempts entrie(s) (untouched >${ICON_RETRY_TTL}s) on save") if $icon_gc;
			
			# --- СТРОГИЙ ДЕТЕРМИНИРОВАННЫЙ СБОРЩИК МУСОРА КЭША ---
			# Единственный критерий защиты файла в кэше — физическое присутствие URL потока в списке настроек.
			# Наличие или отсутствие ссылки на иконку в UI здесь не проверяется!
			my %valid_hashes;
			for my $st (@$stations) {
				my $u = $st->{url} // '';
				if ($u) {
					$valid_hashes{ $class->_get_url_hash($u) } = 1;
				}
			}

			if (-d $logo_dir && opendir(my $dh, $logo_dir)) {
				my $deleted_count = 0;
				while (my $file = readdir($dh)) {
					next if $file =~ /^\./; # Пропускаем . и ..
					
					if ($file =~ /^([a-f0-9]{32})\.(png|jpg|jpeg|gif|ico|svg|webp)(?:\.tmp)?$/i) {
						my $hash = $1;
						if (!$valid_hashes{$hash}) {
							my $full_path = File::Spec->catfile($logo_dir, $file);
							if (unlink $full_path) {
								$deleted_count++;
								$log->debug("[GC] Deleted orphaned cache file: $file");
							} else {
								$log->warn("[GC] Failed to delete '$file': $!");
							}
						} else {
							#$log->debug("RadioStationList: [DBG-GC] Protecting active station file: $file");
						}
					}
				}
				closedir($dh);
				if ($deleted_count > 0) {
					$log->info("Garbage collector cleaned $deleted_count orphaned file(s).");
				}
			}
		}
	}
	return $needs_update;
}

# ПОДГОТОВКА ДАННЫХ ДЛЯ ШАБЛОНА
sub _prepare_display_stations {
	my ($class, $logo_dir) = @_;

	my $display_stations = [];

	for my $st (@{$prefs->get('stations') || []}) {
		my $name          = $st->{name};
		my $url           = $st->{url} || '';
		my $icon_url      = $st->{icon} || '';
		my $final_icon    = '/plugins/RadioStationList/html/images/nologo.svg';
		my $found_on_disk = 0;
		my $icon_state    = 'NO_URL'; # Безопасный scope, доступный для push в конце цикла
		my $icon_source   = 'url';   # то же самое, для push в конце цикла
		my $found_ext;

		if ($url) {
			my $st_url_md5 = $class->_get_url_hash($url);

			# 1. Единая проверка диска: ищем файл по хэшу URL
			if (-d $logo_dir) {
				for my $ext (qw(png jpg jpeg gif ico svg webp)) {
					my $path = File::Spec->catfile($logo_dir, "$st_url_md5.$ext");
					if (-e $path) {
						my @stat = stat($path);
						my $mtime = @stat ? $stat[9] : 0;
						
						if ($ext eq 'webp') {
							# Направляем браузер в наш новый сырой обработчик
							$final_icon = "/plugins/RadioStationList/webp-preview/$st_url_md5?v=$mtime";
						} else {
							# Стандартная статика LMS
							$final_icon = "/plugins/RadioStationList/html/RadioLogo/$st_url_md5.$ext?v=$mtime";
						}
						
						$found_on_disk = 1;
						$found_ext = $ext;
						last;
					}
				}
			}
			# Источник картинки — явный флаг из _process_custom_logos, а не "icon
			# пуст ли": локальный файл теперь перекрывает даже заданный URL, так что
			# по icon-полю больше нельзя понять, откуда взялась картинка в HAS_CACHE.
			$icon_source = $Plugins::RadioStationList::Plugin::custom_logo_active_urls{$url} ? 'local' : 'url';
			# 2. Принятие решения конечным автоматом (State Machine)
			if ($found_on_disk) {
				$icon_state = 'HAS_CACHE';
			} else {
				if ($icon_url =~ m{^https?://}i) {
					my $is_perm_failed  = $Plugins::RadioStationList::Plugin::permanent_failures{$url};
					my $is_downloading  = $Plugins::RadioStationList::Plugin::downloading{$st_url_md5};
					my $temp_fail_time  = $Plugins::RadioStationList::Plugin::failed_downloads{$url} || 0;
					my $is_temp_failed  = ($temp_fail_time > 0 && (time() - $temp_fail_time < 3600)) ? 1 : 0;

					if ($is_downloading) {
						# Активная закачка прямо сейчас (включая прокси-фоллбэк) — держим
						# клиента в PENDING, чтобы поллинг не останавливался раньше времени
						$icon_state = 'PENDING_DOWNLOAD';
						$final_icon = $icon_url;
					} elsif ($is_perm_failed) {
						$icon_state = 'FETCH_FAILED_PERM';
						$final_icon = $icon_url; # ОТДАЕМ ОРИГИНАЛ! Пусть браузер попробует.
					} elsif ($is_temp_failed) {
						$icon_state = 'FETCH_FAILED_TEMP';
						$final_icon = $icon_url; # Отдаем URL, браузер попытается сам
					} else {
						$icon_state = 'PENDING_DOWNLOAD';
						$final_icon = $icon_url; # Ждем скачивания, браузер показывает URL
					}
				} else {
					# Ссылки нет и на диске пусто -> показываем дефолтную заглушку
					$icon_state = 'NO_URL';
					$final_icon = '/plugins/RadioStationList/html/images/nologo.svg';
				}
			}
		}

		push @$display_stations, {
			name         	=> $name // '',
			url          	=> $url,
			icon         	=> ($icon_url && $icon_url !~ m{^/?html/images/}) ? $icon_url : '',
			display_icon 	=> $final_icon, 
			icon_state      => $icon_state, # <-- Передаем статус конечного автомата в шаблон
			icon_source     => $icon_source, # <-- 'local'/'url': откуда взялась картинка в HAS_CACHE
			# Файл WebP. Браузер в настройках его отрисует напрямую (через webp-preview),
			# но для плейлистов аппаратных плееров LMS он не поддерживается.
			# Показываем бейдж-предупреждение. Отправка в плейлист регулируется
			# галочкой 'allow_webp_playlist' в Plugin.pm.
			icon_unsupported => ($found_ext && $found_ext eq 'webp') ? 1 : 0,
			bitrate      	=> $st->{bitrate} || 0,
			codec 			=> $st->{codec} || '',
			tags        	=> $st->{tags}        || '',
			countrycode 	=> $st->{countrycode} || '',
			country     	=> $st->{country}     || '',
			homepage     	=> $st->{homepage}    || '',
			uuid         	=> $st->{uuid}        || '',
		};
	}

	my $raw_bytes = eval { encode_json($display_stations) } // '[]';
	return ($display_stations, decode_utf8($raw_bytes));
}

1;