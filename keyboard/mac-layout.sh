#!/bin/bash
# Print the Linux (XKB) keyboard layout matching this Mac's current one:
#   "<layout> <variant>"   e.g. "ch de" for macOS Swiss German, "us" for U.S./ABC.
# Unknown layouts fall back to "us" with a note on stderr.
id=$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null)
id=${id#com.apple.keylayout.}
case $id in
  US|ABC|USExtended|ABC-India|Australian) echo "us" ;;
  USInternational-PC|ABC-Extended) echo "us intl" ;;
  Dvorak|DVORAK-QWERTYCMD) echo "us dvorak" ;;
  Colemak) echo "us colemak" ;;
  British|British-PC|ABC-QWERTZ) echo "gb" ;;
  Irish|IrishExtended) echo "ie" ;;
  Canadian|Canadian-CSA|CanadianFrench-PC) echo "ca" ;;
  German) echo "de" ;;
  Austrian) echo "at" ;;
  SwissGerman) echo "ch de" ;;
  SwissFrench) echo "ch fr" ;;
  French|French-PC|French-numerical) echo "fr" ;;
  Belgian) echo "be" ;;
  Dutch) echo "nl" ;;
  Italian|Italian-Pro) echo "it" ;;
  Spanish|Spanish-ISO) echo "es" ;;
  Portuguese) echo "pt" ;;
  Brazilian|Brazilian-ABNT2|Brazilian-Pro) echo "br" ;;
  Danish) echo "dk" ;;
  Swedish|Swedish-Pro) echo "se" ;;
  Norwegian|NorwegianExtended) echo "no" ;;
  Finnish|FinnishExtended|FinnishSami-PC) echo "fi" ;;
  Icelandic) echo "is" ;;
  Polish|PolishPro) echo "pl" ;;
  Czech) echo "cz" ;;
  Czech-QWERTY) echo "cz qwerty" ;;
  Slovak|Slovak-QWERTY) echo "sk" ;;
  Hungarian|Hungarian-QWERTY) echo "hu" ;;
  Slovenian) echo "si" ;;
  Croatian|Croatian-PC) echo "hr" ;;
  Romanian|Romanian-Standard) echo "ro" ;;
  Estonian) echo "ee" ;;
  Latvian) echo "lv" ;;
  Lithuanian) echo "lt" ;;
  Turkish|Turkish-QWERTY|Turkish-QWERTY-PC|Turkish-Standard) echo "tr" ;;
  Greek|GreekPolytonic) echo "gr" ;;
  Russian|RussianWin|Russian-Phonetic) echo "ru" ;;
  Ukrainian|Ukrainian-PC) echo "ua" ;;
  Hebrew|Hebrew-QWERTY|Hebrew-PC) echo "il" ;;
  *) echo "keyboard: no Linux match for macOS layout '${id:-?}', using us" >&2; echo "us" ;;
esac
