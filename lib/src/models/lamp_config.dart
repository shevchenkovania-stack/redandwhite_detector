import 'frame_features.dart';

/// Все настраиваемые числа детектора в одном месте.
///
/// В логике извлечения признаков, оценки и автомата не должно быть ни одного
/// «магического числа» — только ссылки на этот класс.
///
/// Чисел специально мало. Пороги `whiteOnThreshold`/`redOnThreshold`,
/// `redFracDivisor` и `noiseSigmas` удалены: решение больше не принимается
/// «по доле пикселей относительно выдуманного порога», оно сравнивается с
/// откликом, который лампа показала на калибровке (см. [hitFraction]), а шум
/// фона берётся из измеренной σ. Настраивать нужно только два числа.
class LampConfig {
  const LampConfig({
    this.hitFraction = 0.6,
    this.templateMinSeparation = 6,
    this.offRatio = 0.6,
    this.onConfirmFrames = 2,
    this.offConfirmFrames = 3,
    this.offConfirmMs = 400,
    this.calibrationFrames = LampConfig.defaultCalibrationFrames,
    this.calibrationMaxNoise = 0.03,
    this.calibrationNoiseRatio = 0.35,
    this.baselineMaxAgeMinutes = 180,
    this.subsampleStep = 2,
    this.analysisIsolateThresholdMs = 8,
    this.yuvFullRange = true,
    this.scoreHistoryPoints = 240,
    this.csvFlushLines = 30,
    this.whiteMinChannel = 170,
    this.redMargin = 60,
    this.redMinValue = 110,
    this.liveReference = false,
    this.referenceWindowFrames = 20,
    this.referencePercentile = 0.2,
    this.referenceNoiseSigmas = 6,
    this.referenceMinRise = 0.03,
    this.referenceMaxLevel = 0.15,
    this.ringScale = 1.7,
    this.lumaPercentile = 0.9,
    this.clipLuma = 248,
    // Рабочий способ по умолчанию — HSV плюс калибровка (слово заказчика
    // 25.11.2026: «совмести наработку hsv и калибровку всё в одно, будем только
    // с калибровкой работать»). Число не вкусовое: по разметке координат рукой
    // заказчика (`tools/hsv_decide.py sign 0.06 3.0 auto manual`, журнал 46) на
    // размеченных записях это 60 ошибок против 100 у того же автомата без
    // выученной границы.
    this.hsvReference = true,
    this.hsvCoolValueMin = 217,
    this.hsvCoolSatMax = 64,
    this.hsvWarmValueMin = 140,
    this.hsvWarmSatMin = 115,
    this.hsvWarmHueMax = 45,
    this.hsvMinRise = 0.06,
    this.hsvMaxLevel = 0.40,
    this.hsvGate = 3.0,
    this.hsvClipValue = 0.97,
    this.hsvClipOwn = 0.90,
    this.hsvClipCross = 0.20,
    this.hsvSignatureNaming = true,
    this.hsvSignatureMinSigmas = 2.0,
    // Признаки геометрии света спецификации v6 §2. Считаются всегда: решением
    // они станут в следующем шаге, но профиль калибровки обязан быть набран
    // теми же числами, которыми решение будет проверяться.
    this.v6Spatial = true,
    this.v6BrightValueMin = 200,
    this.v6CoreValueMin = 235,
    this.v6HueSatMin = 64,
    this.v6CenterSpan = 0.5,
    this.hueBins = 16,
    this.v6MinSigma = 0.02,
    this.v6DScale = 1.0,
    this.v6ReflectionWeight = 0.8,
    this.v6CoreFeatures = LampConfig.defaultV6CoreFeatures,
    this.v6ProfileDecision = true,
    this.v6MinConfidence = 0.35,
    this.v6ReflectionVeto = 0.65,
  });

  /// Доля измеренного отклика, при которой лампа считается включённой.
  /// Амплитуда `1.0` = «рамка изменилась ровно так, как на калибровке, когда
  /// эту лампу держали зажжённой». `0.6` выбрано, чтобы затекание чужой лампы
  /// (на живых замерах — доли отклика) не проходило, а удар той же лампы по
  /// той же яркости проходил с запасом.
  final double hitFraction;

  /// Во сколько раз измеренный отклик лампы должен превышать шум фона,
  /// иначе калибровка отвергается. Это самопроверка: «немой» канал, рамка не
  /// на том колпаке и лампа, которая мигала во время своего шага, дают
  /// отклик того же порядка, что шум, и калибровка не проходит.
  final double templateMinSeparation;

  /// OFF-порог = это число от ON-порога (гистерезис).
  final double offRatio;

  /// Подряд кадров выше ON-порога, чтобы подтвердить включение.
  final int onConfirmFrames;

  /// Подряд кадров ниже OFF-порога, чтобы подтвердить выключение. Это только
  /// нижняя граница числа кадров: физическую длительность правила задаёт
  /// [offConfirmMs], потому что кадры теряются (`_busy`), и три кадра — это и
  /// 100 мс при 30 к/с, и 250 мс при 12 к/с.
  final int offConfirmFrames;

  /// Как ДОЛГО (мс) обязан держаться провал ниже OFF-уровня, чтобы выключение
  /// считалось подтверждённым по длительности (второе, независимое от глубины
  /// условие).
  ///
  /// Правило в одних кадрах здесь бессильно: кадры теряются (`_busy`), и три
  /// кадра — это и 100 мс при 30 к/с, и 300 мс при 10 к/с. Одна физическая
  /// вспышка идёт волной, и внутри горения амплитуда проваливается (замер
  /// 20.11.2026: провал длиной ровно в 3 обработанных кадра при интервале кадра
  /// 24–100 мс, то есть до ~300 мс) — прежнее правило взводилось заново и
  /// считало один удар дважды.
  ///
  /// Гашение подтверждается, если провал либо ушёл к «полу»
  /// ([referenceMinRise]) — тогда лампу просто не видно, и никакая длительность
  /// не нужна, — либо тянется не короче этого числа. 400 мс — не придуманное
  /// число, а промежуток между двумя измеренными: сверху — потолок
  /// внутриударного провала (~300 мс), снизу — кратчайшая пауза между двумя
  /// настоящими ударами (600 мс у тестовой панели на «Быстро»; по спецификации
  /// 18.11.2026 лампа вообще горит, пока её рукой не выключат, то есть реальный
  /// зазор больше). Правило, которого не хватает на провал и которое не съедает
  /// паузу, может лежать только между ними.
  ///
  /// `0` выключает временное условие: остаётся только проверка глубины.
  /// Достать эти два числа из записи умеет `RunAnalyzer`: он измеряет по CSV
  /// длительности провалов и пауз (`DarkRunTiming`).
  final int offConfirmMs;

  /// Сколько пикселей берётся для КАЖДОГО шага калибровки (фон, белая, красная).
  final int calibrationFrames;

  /// Значение [calibrationFrames] по умолчанию — нужно UI для состояния
  /// калибровки до создания конфига.
  static const int defaultCalibrationFrames = 30;

  /// Калибровка шага отвергается, если устойчивая к выбросам σ его кадров выше
  /// этого (в кадре что-то мигало или двигалось: состояние было бы мусорным).
  /// Это допуск шага «фон» — на шагах горящей лампы к нему добавляется
  /// [calibrationNoiseRatio] от измеренного отклика, потому что мигающая лампа
  /// и есть сигнал, а не помеха.
  final double calibrationMaxNoise;

  /// Долю измеренного отклика, которую разрешено занимать шуму на шаге
  /// «лампа горит». Допуск по признаку `j` =
  /// `max(calibrationMaxNoise, это × |значение − фон|)`: при 0.35 мигающая
  /// лампа вправе шуметь на треть собственного отклика (сетевой LED, рука на
  /// выключателе), а признаки, которые вообще не сдвинулись, по-прежнему
  /// держатся строгого порога фона. Без этой добавки калибровка отвергала ровно
  /// те кадры, ради которых собиралась (замер: σ whiteFrac = 0.158 при отклике
  /// 0.65 — лампа мигает в пределах нормы, а шаг «не прошёл»).
  final double calibrationNoiseRatio;

  /// Калибровка старше этого возраста при запуске не загружается.
  final int baselineMaxAgeMinutes;

  /// Шаг подвыборки пикселей: каждый N-й по x и по y.
  final int subsampleStep;

  /// Среднее время анализа кадра выше этого значения => выносить в изолят.
  final double analysisIsolateThresholdMs;

  /// True: Y канал YUV420 считается full range (0..255). False: studio range
  /// 16..235 растягивается в 0..255. Зависит от устройства.
  final bool yuvFullRange;

  /// Сколько точек графика хранить в демо.
  final int scoreHistoryPoints;

  /// Сколько строк CSV буферизовать перед записью на диск.
  final int csvFlushLines;

  /// Пиксель «настоящий белый», если min(R,G,B) ≥ этого значения (0..255).
  ///
  /// Все три цветовых числа измеряются и пишутся в CSV для разбора записей, но
  /// НИ НА ОДНО РЕШЕНИЕ они не влияют: «белый» и «красный» пиксель выбираются
  /// здесь, а какая лампа сработала — решает яркость четырёх областей и то,
  /// куда она легла. Раньше цвет решал, и из-за этого пересвеченная красная
  /// лампа (для сенсора белая) уезжала в белую корзину.
  final double whiteMinChannel;

  /// Пиксель «красный», если R − max(G,B) ≥ этого значения…
  final double redMargin;

  /// …и R ≥ этого значения (отсекает тёмно-бордовые тени).
  final double redMinValue;

  /// Считать вспышку относительно ЖИВОГО отсчёта, а не относительно
  /// сохранённой калибровки.
  ///
  /// Калибровка описывает одну сцену: сменили набор картинок или окно — и
  /// записанный «ноль» уже не тот, что в кадре. Тогда канал либо прилипает к
  /// «горит», либо замолкает. Живой отсчёт берёт «ноль» из последних кадров,
  /// поэтому работает на любой сцене и переживает смену освещения без
  /// перекалибровки. Калибровка остаётся самопроверкой («рамка видит лампу»).
  final bool liveReference;

  /// Глубина окна живого отсчёта в кадрах (~2 с при 10 к/с).
  final int referenceWindowFrames;

  /// Какой процентиль окна считать «полом» (0.2 = 20-й). Процентиль, а не
  /// среднее: вспышка внутри окна сдвинула бы среднее и вычла себя.
  final double referencePercentile;

  /// Во сколько σ окна должен подняться признак, чтобы это была вспышка.
  final double referenceNoiseSigmas;

  /// Абсолютный минимум подъёма: на идеально ровной сцене шум равен нулю, и
  /// порог «6σ» не защищает от единичных пикселей.
  final double referenceMinRise;

  /// Потолок порога ON и одновременно признак того, что живой отсчёт больше
  /// ничего не измеряет.
  ///
  /// Нужен потому, что подъём над «полом» физически ограничен единицей, а `6σ`
  /// потолка не имеет: камера погуляла по сцене — и порог стал 1.2–1.5, до
  /// которого вспышке не достать НИКОГДА (замер 20.11.2026: `onW 1.256`,
  /// `onR 1.521` при подъёме 0.561 — канал молчал до самого перезапуска).
  /// Упереться в потолок значит «окно описывает не темноту, а движение», и
  /// тогда окно набирается заново вместо того, чтобы вечно не досчитывать.
  ///
  /// 0.15 — между измеренным шумом закреплённой камеры (6σ ≈ 0.03–0.12) и
  /// минимальным измеренным подъёмом настоящей лампы (0.12–0.56).
  final double referenceMaxLevel;

  /// Во сколько раз расширять рамку для кольца-ореола. У настоящих ламп
  /// сигнал живёт в ореоле: колпак при включении может даже побледнеть
  /// (пересвет), а растёт именно кольцо. 1.0 — кольцо не считается.
  final double ringScale;

  /// Какой процентиль яркости брать по области (0.9 = p90, 0.95 = p95).
  /// Процентиль, а не максимум: один яркий пиксель — это блик, пылинка или
  /// шум квантования, а верх распределения показывает, какая площадь колпака
  /// реально засвечена.
  final double lumaPercentile;

  /// Яркость пикселя (0..255), с которой он считается пересвеченным: выше
  /// него сенсор стоит на потолке, и запаса яркости там уже нет. Доля таких
  /// пикселей — признак качества кадра, а не признак лампы.
  final double clipLuma;

  /// Считать вспышку по HSV-долям цветных пикселей, а не по яркости области.
  ///
  /// Третий способ счёта, отделённый от двух прежних специально: он решает не
  /// «стало ли в рамке светлее», а «появилась ли в рамке площадь обесцвеченно
  /// белого или площадь насыщенного красного». Причина в замерах: на 86
  /// включениях, найденных самой HSV-моделью по 11 видео стенда 23.11.2026
  /// (`tools/hsv_stats.py`), подъём `p90` яркости равен 0.068…0.753 при пороге
  /// живого отсчёта 0.062…0.15 — и в 8 случаях из 86 до порога не дотягивает
  /// (это и есть «не всегда считает вспышку»). Доля цветных пикселей на тех же
  /// включениях поднимается на 0.061…1.0, а оттенок от выдержки не меняется.
  ///
  /// Включённый способ ищет событие по скользящему «полу» последних
  /// [referenceWindowFrames] кадров — то есть само включение считается и без
  /// калибровки. Но работает этот способ теперь только вместе с калибровкой:
  /// имя вспышки выучивается по трём её состояниям ([hsvSignatureNaming]), и без
  /// них детектор не запускается (журнал 46, слово заказчика «будем только с
  /// калибровкой работать»). Переключение способа сбрасывает окна, потому что
  /// они набраны в других единицах.
  final bool hsvReference;

  /// Пиксель «белый» в HSV: яркость (0..255) не ниже этого…
  ///
  /// 217 = 0.85·255 — нижняя граница той же пары, что у офлайн-модели
  /// (`hsv_probe.COOL_V_MIN`). Цена измерена на кадрах, где модель посчитала
  /// белую вспышку (`tools/hsv_bounds.py`, белая зона 49×49): площадь «почти
  /// без оттенка» при 0.75 равна 881…1908 px/кадр, при 0.85 — 784…1759, при
  /// 0.95 — 644…1603. Граница стоит 0…29 % площади (в среднем ~11 %), и ровно
  /// она не даёт тёмной стене и ореолу сойти за лампу.
  final double hsvCoolValueMin;

  /// …и насыщенность (0..255 по шкале OpenCV) не выше этого.
  ///
  /// 64 = 0.25·255 (`hsv_probe.COOL_S_MAX`). Смысл пары в том, что в «белые»
  /// не попадает ни тёмная стена (яркости нет), ни оранжевый ореол (насыщения
  /// много). По замерам граница стоит своих процентов: на кадрах белой
  /// вспышки p50 насыщенности ярких пикселей 0.000…0.35, а окно 0.25 теряет
  /// 0…13 % площади против 0.15 и набирает 0…11 % против 0.35 — то есть
  /// правило стоит на месте, а не на выбранном числе. То, что отбор различает
  /// белый свет и оранжевый ореол, проверено ещё и на синтетике
  /// `test/hsv_reference_test.dart`.
  final double hsvCoolSatMax;

  /// Пиксель «красный» в HSV: яркость (0..255) не ниже этого…
  ///
  /// 140 = 0.55·255 (`hsv_probe.WARM_V_MIN`) отсекает тёмную тёплую часть кадра
  /// — по оттенку она совпадает с лампой, но заметно темнее. Цена измерена на
  /// кадрах красной вспышки (`tools/hsv_bounds.py`, красная зона 49×49): площадь
  /// оттенокного ядра при 0.45 равна 201…1780 px/кадр, при 0.55 — 128…1716, при
  /// 0.65 — 44…1631; доля ядра темнее 0.55 доходит до 47 % только на одной
  /// записи (190707). Перебор той же границы (`hsv_decide.py vmin 0.45 0.55
  /// 0.65`) даёт 43/36, 46/40 и 43/41 событий — на этих записях граница исход
  /// не решает, и без разметки «что горело» выбрать её по числам нельзя.
  final double hsvWarmValueMin;

  /// …и насыщенность (0..255 по шкале OpenCV) не ниже этого.
  ///
  /// 115 = 0.45·255 (`hsv_probe.WARM_S_MIN`): не даёт в «красные» ни белой
  /// лампы, ни выбеленного ею фона. Граница измерена с обеих сторон
  /// (`tools/hsv_bounds.py`): на кадрах красной вспышки площадь оттенокного
  /// ядра при S ≥ 0.35 равна 369…1794 px/кадр, при 0.45 — 128…1716, при 0.55 —
  /// 39…1648; в фоне той же зоны — 1.9…783, 0…765 и 0…672 соответственно.
  /// Сужать дальше нельзя (на 190707 ядро теряет 70 % площади), расширять
  /// бессмысленно: на той же записи 0.35 добавляет к ядру +189 %, а к фону
  /// только +79 %, и там уже фон краснее «горящей» лампы (180 px/кадр против
  /// 128) — то есть красные события 190707 держатся не на площади лампы, а на
  /// шуме той же самой зоны.
  final double hsvWarmSatMin;

  /// Полуокно оттенка вокруг чистого красного, в градусах. Пиксель красный,
  /// если его оттенок ≤ этого или ≥ 360 − этого.
  ///
  /// 45°, а не «красный до 18°», потому что лампа на стенде светит оранжевым.
  /// Замер на кадрах, где модель сама посчитала красную вспышку (`tools/
  /// hsv_bounds.py`, красная зона 49×49): медиана оттенка ядра 25.6…34.7° по 11
  /// записям, p95 33.6…39.8°. Цена окна измерена в пикселях на кадр: при 18°
  /// остаётся 0…70 px, при 30° — 82…1022, при 45° — 128…1716, при 60°
  /// прирост меньше 0.4 px. То есть узкое окно убивает признак целиком, а
  /// шире 45° расширять нечего. Окно обязано быть и не слишком узким по
  /// площади, и не широким: широкий «красный» начинает ловить дерево и стену.
  final double hsvWarmHueMax;

  /// Абсолютный минимум подъёма HSV-доли. Порог «k·σ» на ровной сцене равен
  /// нулю, а единичные пиксели оттенка там есть всегда.
  ///
  /// 0.06 — вдвое выше измеренного шума закреплённой камеры (6σ тёмной части по
  /// 11 записям 0…0.13) и ровно тот подъём, который дают худшие из посчитанных
  /// включений (0.061): ниже этого порога отличить вспышку от шума уже нельзя.
  final double hsvMinRise;

  /// Потолок порога HSV-доли. Выше него канал молчит всегда: подъём доли
  /// физически ограничен единицей, а ушедшая в движение камера раздувает σ окна.
  ///
  /// По 11 записям потолок не пригодился ни разу: наибольший «неограниченный»
  /// 6σ равен 0.776 (белая зона 191508), но раньше срабатывает половина размаха
  /// — ни один порог замеры не подняли выше 0.395. Число стоит против сцены,
  /// которой в этих замерах нет (телефон на ходу, лампа тусклая).
  final double hsvMaxLevel;

  /// Во сколько раз подъём СВОЕГО канала обязан превысить подъём ЧУЖОГО канала
  /// (его зоны), чтобы вспышка засчиталась.
  ///
  /// Нужно потому, что белая лампа заливает и красную зону, и наоборот, а
  /// спецификация говорит, что одновременно они не горят: при двух подъёмах
  /// разом прав тот, что больше. Выбрано 3.0 по человеческой разметке 23.11.2026
  /// (заказчик продиктовал ПОРЯДОК включений б/к для 10 записей, 68 событий).
  /// Оценщик — `tools/hsv_decide.py cmp`, ошибка = лишние + пропущенные события
  /// после выравнивания ленты модели с разметкой: 30 при gate 1.0, 23 при 1.5,
  /// 20 при 2.0, 17 при 3.0, снова рост к 4.0. Худший остаток — не вето, а
  /// перетекание, которое вето не ловит: `191142` (б к к к -> 4 белых) и
  /// `191158` (б к б к бк -> 5/5): там чужой канал поднимается на кадр РАНЬШЕ
  /// своего, а вето сравнивает один и тот же кадр. Память вето (`mem`) по
  /// разметке лучше не делает — при gate 3.0 ошибок 17, а не меньше.
  ///
  /// Число проверено заново 25.11.2026, после того как центры рамок стали
  /// ручными (журнал 45, 46): по всей разметке `truth 3.0` даёт 121 ошибку
  /// против 130 при `truth 1.5`, и по корпусам это
  /// `стенд 54 / pixel 63 / pixel-стена 2 / iphone 2` против
  /// `56 / 70 / 2 / 2`. Значит подбор не устарел от перестановки рамок.
  final double hsvGate;

  /// Яркость (p90 зоны в долях 0..1), с которой зона считается стоящей на
  /// потолке сенсора: запаса яркости там нет, и оттенок перестаёт быть
  /// измеримым.
  final double hsvClipValue;

  /// Доля СВОЕГО цвета, при которой вдобавок к потолку цвета уже не видно
  /// вовсе — зона залита добела или добела-с-оттенком.
  final double hsvClipOwn;

  /// Заметная (0.20) доля ЧУЖОГО цвета в той же залитой зоне: два цвета в
  /// одном кадре доказать нельзя, поэтому состояние канала не меняется. Без
  /// этого кадра пересвеченная белая лампа успевала «погасить» красную.
  final double hsvClipCross;

  /// Называть вспышки по правилу, выученному калибровкой, а не по догадке «у
  /// своей лампы поднят свой канал».
  ///
  /// Доказано на замерах 25.11.2026: на офисном стенде красная лампа даёт
  /// больший подъём обесцвеченных пикселей, чем белая, поэтому догадка там не
  /// просто шумна, а перевернута. Событие ищется по максимуму четырёх рядов, а
  /// имя ему даёт граница, измеренная на шагах «2 БЕЛАЯ» и «3 КРАСНАЯ»
  /// (`HsvSignature.learn`, журнал 37: 32 ошибки → 3 на клипах с настоящими
  /// переключениями). Выключено — прежний путь с вето [hsvGate]; если
  /// калибровка разделения не дала, детектор откатывается на него сам.
  ///
  /// С 25.11.2026 это не опция рабочего пути, а сам путь: HSV-счёт запущен
  /// только после трёх состояний калибровки (журнал 46). Проверено на разметке
  /// координат рукой заказчика, leave-one-out, обнаружение тем же автоматом:
  /// `sign 0.06 3.0 auto manual` даёт 60 ошибок вместо 100 у автомата с вето,
  /// по корпусам pixel 63 → 28 (признак `зона1/cool`, порог 0.217, разделение
  /// 15σ), стенд 33 → 32, а iphone и pixel-стена остаются без второго класса —
  /// там учиться нечему, и имена решает там прежнее вето.
  final bool hsvSignatureNaming;

  /// Ниже какого разделения двух ламп (в σ) калибровка не даёт права называть
  /// вспышки и остаётся прежнее правило. 2.0 — тот же смысл, что и у
  /// [templateMinSeparation]: отклик обязан быть вдвое больше шума шага.
  final double hsvSignatureMinSigmas;

  /// Считать ли признаки геометрии света (медианы V/S, ядро, связные области,
  /// центр против остальной ROI, распределение оттенка) — блок v6 §2.
  ///
  /// Выключено возвращает прежний облик кадра: поля вектора остаются нулями, а
  /// решение по профилям на нули не опирается (см. `docs/АЛГОРИТМ_ВЕРСИИ.md`).
  /// Включено по умолчанию, потому что калибровка обязана набирать те же числа,
  /// по которым потом решает: профиль, снятый без ядра, проверяать ядром
  /// нельзя.
  final bool v6Spatial;

  /// Яркость (V, 0..255), с которой пиксель считается ярким — знаменатель
  /// [FrameFeatures.brightFrac]. 200 ≈ 0.78·255: выше порога, на котором
  /// белая лампа уже светит, и ниже потолка сенсора.
  final double v6BrightValueMin;

  /// Яркость пикселя, с которой он попадает в ЯДРО источника
  /// ([FrameFeatures.coreAreaFrac], [FrameFeatures.coreIntensity],
  /// [FrameFeatures.coreRegions], [FrameFeatures.coreCenterFrac]).
  /// 235 ≈ 0.92·255 — это верхняя часть гистограммы яркости той же зоны, по
  /// которой [clipLuma] меряет пересвет: ядро обязано быть ярче тела лампы и
  /// не обязано быть на самом потолке, иначе оно исчезало бы в каждом
  /// пересвеченном кадре.
  final double v6CoreValueMin;

  /// Насыщенность (0..255), с которой пиксель считается цветным и попадает в
  /// гистограмму оттенка. 64 ≈ 0.25·255 — тот же порог обесцвеченности, что у
  /// [hsvCoolSatMax], взятый с другой стороны: оттенок имеет смысл мерять только
  /// там, где цвет есть.
  final double v6HueSatMin;

  /// Доля стороны рамки, занимающая центральное окно поверхности
  /// ([FrameFeatures.coreCenterFrac], [FrameFeatures.centerContrast]). 0.5 —
  /// четверть площади ROI в середине: при меньшем окне ядро лампы на плохой
  /// рамке целиком оказывается «вне центра», при большем окно сливается с
  /// остальной областью и признак перестаёт что-либо различать.
  final double v6CenterSpan;

  /// Число корзин гистограммы оттенка. 16 по 22.5° — красное («вокруг нуля»,
  /// v6 §4 требует именно корзин из-за перехода шкалы) занимает корзины 0 и 15,
  /// и они суммируются отдельно; дальше число только размывает рисунок.
  final int hueBins;

  /// Все признаки вектора — профиль по умолчанию считает их все.
  ///
  /// Список не «сокращает данные», а выбирает, чем доказывать: на стенде имеет
  /// смысл оставить только геометрию света (`coreAreaFrac`, `coreCenterFrac`,
  /// `centerContrast`), чтобы проверить, решает ли она одна.
  static const List<V6Feature> defaultV6CoreFeatures = V6Feature.values;

  /// Пол разброса признака в ДОЛЯХ от его же уровня (v6 §8).
  ///
  /// На идеально ровной синтетике и на лампе, снятой без дрожащего света, IQR
  /// равен нулю, и первое же дрожание признака стало бы бесконечным
  /// расстоянием до профиля. Пол привязан к уровню, а не к абсолютному числу,
  /// потому что вектор смешан по шкалам: `medianV` лежит в 0..255, а
  /// `coreAreaFrac` — в 0..1.
  final double v6MinSigma;

  /// Нижний знаменатель симметричных мер «ближе к ON, чем к OFF» и «ближе к
  /// spill, чем к ON».
  ///
  /// Обе меры — отношение разности двух расстояний к их сумме; когда кадр
  /// одинаково близок к обоим эталонам (сцена не двигалась вовсе), сумма
  /// стремится к нулю и отношение теряет смысл. Знаменатель не меньше этого
  /// числа означает: заведомо слабый отклик не превращается в уверенное «0» или
  /// «1» делением двух шумов. Расстояния измеряются в σ собственного разброса,
  /// поэтому 1.0 здесь — «одно среднее отклонение».
  final double v6DScale;

  /// Во сколько раз полное (1.0) подозрение на отражение гасит уверенность
  /// лампы (v6 §5, §9.7).
  ///
  /// Кадр, который одинаково похож на своё включение и на засветку от соседней
  /// лампы, спецификация требует НЕ подтверждать, но число обязано оставаться
  /// сравниваемым между двумя лампами, поэтому гашение — до 20 %, а не до нуля:
  /// при 0 уверенность пропала бы и у настоящей лампы, которую профиль тоже
  /// «подозревает».
  final double v6ReflectionWeight;

  /// Признаки, которыми решение сравнивает кадр с профилем.
  ///
  /// По умолчанию — весь вектор. Числом можно оставить только геометрию света:
  /// именно это на стенде и проверяется первым, потому что спецификация v6 §2
  /// требует различать «своё включение» и «отражение соседней» по РИСУНКУ,
  /// а не по яркости, и должно быть видно, что даёт именно рисунок.
  final List<V6Feature> v6CoreFeatures;

  /// Слово профилям калибровки: разрешено ли им ОТКАЗАТЬ кадру подтвердить
  /// лампу (v6 §5, §9.7).
  ///
  /// Право дано только отказу, а не имени: событие по-прежнему находит
  /// измеренный HSV-путь (60 ошибок на разметке заказчика, журнал 46), а
  /// профили могут убрать кадр, похожий на отражение соседней лампы или
  /// непохожий ни на одно включение. Один флаг поэтому делает честный A/B на
  /// ОДНОЙ записи: выключено — дерево совпадает с v5, включено — отличия
  /// видны по колонкам `*_conf`/`*_suspicion` и по счётчику отказов.
  ///
  /// Это же число — различие двух режимов спецификации v6 §MODES: [countMode]
  /// показывает `hsv` при выключенном и `hsvCalibration` при включённом, а
  /// [withCountMode] ставит его по выбору режима. Отдельного флага на режим
  /// поэтому нет: два названия одного числа однажды разошлись бы, и UI врал
  /// бы о том, как считать кадр.
  final bool v6ProfileDecision;

  /// Ниже какой уверенности (0..1) кадр не подтверждает лампу, а считается
  /// UNKNOWN: «в рамке что-то изменилось, но на включение это не похоже»
  /// (v6 §11 требует именно такого состояния, а не молчаливого пропуска).
  ///
  /// 0.35, а не половина: уверенность `0.5` означает «кадр одинаково далёк от
  /// темноты и от включения», то есть ровно то, на что переходный кадр руки
  /// или половина волны вспышки и тянет. Отказывать им — значит потерять
  /// настоящие удары, а этого правило приёмки не прощает.
  final double v6MinConfidence;

  /// При каком подозрении на отражение (0..1) кадр отказывается подтверждать
  /// лампу, если соседняя объясняет его лучше (v6 §5: «reject if spatial
  /// pattern indicates reflection»).
  ///
  /// 0.65 — выше середины с запасом: ровно на середине (`0.5`) ON и spill
  /// неразличимы, и отказываться там означало бы терять половину настоящих
  /// включений. Отказ срабатывает только вместе с тем, что соседняя лампа
  /// объясняет кадр лучше, — то есть когда называть есть чем.
  final double v6ReflectionVeto;

  /// Копия с одним-двумя изменёнными числами. Менять настройку стенда имеет
  /// смысл по одному фактору за раз, иначе непонятно, что именно улучшило или
  /// сломало результат. Перечислять здесь обязано все поля: молча сброшенное
  /// число было бы тем самым «одновременным изменением двух факторов».
  LampConfig copyWith({
    double? hitFraction,
    double? templateMinSeparation,
    double? offRatio,
    int? onConfirmFrames,
    int? offConfirmFrames,
    int? offConfirmMs,
    int? calibrationFrames,
    double? calibrationMaxNoise,
    double? calibrationNoiseRatio,
    int? baselineMaxAgeMinutes,
    int? subsampleStep,
    double? analysisIsolateThresholdMs,
    bool? yuvFullRange,
    int? scoreHistoryPoints,
    int? csvFlushLines,
    double? whiteMinChannel,
    double? redMargin,
    double? redMinValue,
    bool? liveReference,
    int? referenceWindowFrames,
    double? referencePercentile,
    double? referenceNoiseSigmas,
    double? referenceMinRise,
    double? referenceMaxLevel,
    double? ringScale,
    double? lumaPercentile,
    double? clipLuma,
    bool? hsvReference,
    double? hsvCoolValueMin,
    double? hsvCoolSatMax,
    double? hsvWarmValueMin,
    double? hsvWarmSatMin,
    double? hsvWarmHueMax,
    double? hsvMinRise,
    double? hsvMaxLevel,
    double? hsvGate,
    double? hsvClipValue,
    double? hsvClipOwn,
    double? hsvClipCross,
    bool? hsvSignatureNaming,
    double? hsvSignatureMinSigmas,
    bool? v6Spatial,
    double? v6BrightValueMin,
    double? v6CoreValueMin,
    double? v6HueSatMin,
    double? v6CenterSpan,
    int? hueBins,
    double? v6MinSigma,
    double? v6DScale,
    double? v6ReflectionWeight,
    List<V6Feature>? v6CoreFeatures,
    bool? v6ProfileDecision,
    double? v6MinConfidence,
    double? v6ReflectionVeto,
  }) {
    return LampConfig(
      hitFraction: hitFraction ?? this.hitFraction,
      templateMinSeparation:
          templateMinSeparation ?? this.templateMinSeparation,
      offRatio: offRatio ?? this.offRatio,
      onConfirmFrames: onConfirmFrames ?? this.onConfirmFrames,
      offConfirmFrames: offConfirmFrames ?? this.offConfirmFrames,
      offConfirmMs: offConfirmMs ?? this.offConfirmMs,
      calibrationFrames: calibrationFrames ?? this.calibrationFrames,
      calibrationMaxNoise: calibrationMaxNoise ?? this.calibrationMaxNoise,
      calibrationNoiseRatio:
          calibrationNoiseRatio ?? this.calibrationNoiseRatio,
      baselineMaxAgeMinutes:
          baselineMaxAgeMinutes ?? this.baselineMaxAgeMinutes,
      subsampleStep: subsampleStep ?? this.subsampleStep,
      analysisIsolateThresholdMs:
          analysisIsolateThresholdMs ?? this.analysisIsolateThresholdMs,
      yuvFullRange: yuvFullRange ?? this.yuvFullRange,
      scoreHistoryPoints: scoreHistoryPoints ?? this.scoreHistoryPoints,
      csvFlushLines: csvFlushLines ?? this.csvFlushLines,
      whiteMinChannel: whiteMinChannel ?? this.whiteMinChannel,
      redMargin: redMargin ?? this.redMargin,
      redMinValue: redMinValue ?? this.redMinValue,
      liveReference: liveReference ?? this.liveReference,
      referenceWindowFrames:
          referenceWindowFrames ?? this.referenceWindowFrames,
      referencePercentile: referencePercentile ?? this.referencePercentile,
      referenceNoiseSigmas: referenceNoiseSigmas ?? this.referenceNoiseSigmas,
      referenceMinRise: referenceMinRise ?? this.referenceMinRise,
      referenceMaxLevel: referenceMaxLevel ?? this.referenceMaxLevel,
      ringScale: ringScale ?? this.ringScale,
      lumaPercentile: lumaPercentile ?? this.lumaPercentile,
      clipLuma: clipLuma ?? this.clipLuma,
      hsvReference: hsvReference ?? this.hsvReference,
      hsvCoolValueMin: hsvCoolValueMin ?? this.hsvCoolValueMin,
      hsvCoolSatMax: hsvCoolSatMax ?? this.hsvCoolSatMax,
      hsvWarmValueMin: hsvWarmValueMin ?? this.hsvWarmValueMin,
      hsvWarmSatMin: hsvWarmSatMin ?? this.hsvWarmSatMin,
      hsvWarmHueMax: hsvWarmHueMax ?? this.hsvWarmHueMax,
      hsvMinRise: hsvMinRise ?? this.hsvMinRise,
      hsvMaxLevel: hsvMaxLevel ?? this.hsvMaxLevel,
      hsvGate: hsvGate ?? this.hsvGate,
      hsvClipValue: hsvClipValue ?? this.hsvClipValue,
      hsvClipOwn: hsvClipOwn ?? this.hsvClipOwn,
      hsvClipCross: hsvClipCross ?? this.hsvClipCross,
      hsvSignatureNaming: hsvSignatureNaming ?? this.hsvSignatureNaming,
      hsvSignatureMinSigmas:
          hsvSignatureMinSigmas ?? this.hsvSignatureMinSigmas,
      v6Spatial: v6Spatial ?? this.v6Spatial,
      v6BrightValueMin: v6BrightValueMin ?? this.v6BrightValueMin,
      v6CoreValueMin: v6CoreValueMin ?? this.v6CoreValueMin,
      v6HueSatMin: v6HueSatMin ?? this.v6HueSatMin,
      v6CenterSpan: v6CenterSpan ?? this.v6CenterSpan,
      hueBins: hueBins ?? this.hueBins,
      v6MinSigma: v6MinSigma ?? this.v6MinSigma,
      v6DScale: v6DScale ?? this.v6DScale,
      v6ReflectionWeight: v6ReflectionWeight ?? this.v6ReflectionWeight,
      v6CoreFeatures: v6CoreFeatures ?? this.v6CoreFeatures,
      v6ProfileDecision: v6ProfileDecision ?? this.v6ProfileDecision,
      v6MinConfidence: v6MinConfidence ?? this.v6MinConfidence,
      v6ReflectionVeto: v6ReflectionVeto ?? this.v6ReflectionVeto,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'hitFraction': hitFraction,
    'templateMinSeparation': templateMinSeparation,
    'offRatio': offRatio,
    'onConfirmFrames': onConfirmFrames,
    'offConfirmFrames': offConfirmFrames,
    'offConfirmMs': offConfirmMs,
    'calibrationFrames': calibrationFrames,
    'calibrationMaxNoise': calibrationMaxNoise,
    'calibrationNoiseRatio': calibrationNoiseRatio,
    'baselineMaxAgeMinutes': baselineMaxAgeMinutes,
    'subsampleStep': subsampleStep,
    'analysisIsolateThresholdMs': analysisIsolateThresholdMs,
    'yuvFullRange': yuvFullRange,
    'scoreHistoryPoints': scoreHistoryPoints,
    'csvFlushLines': csvFlushLines,
    'whiteMinChannel': whiteMinChannel,
    'redMargin': redMargin,
    'redMinValue': redMinValue,
    'liveReference': liveReference,
    'referenceWindowFrames': referenceWindowFrames,
    'referencePercentile': referencePercentile,
    'referenceNoiseSigmas': referenceNoiseSigmas,
    'referenceMinRise': referenceMinRise,
    'referenceMaxLevel': referenceMaxLevel,
    'ringScale': ringScale,
    'lumaPercentile': lumaPercentile,
    'clipLuma': clipLuma,
    'hsvReference': hsvReference,
    'hsvCoolValueMin': hsvCoolValueMin,
    'hsvCoolSatMax': hsvCoolSatMax,
    'hsvWarmValueMin': hsvWarmValueMin,
    'hsvWarmSatMin': hsvWarmSatMin,
    'hsvWarmHueMax': hsvWarmHueMax,
    'hsvMinRise': hsvMinRise,
    'hsvMaxLevel': hsvMaxLevel,
    'hsvGate': hsvGate,
    'hsvClipValue': hsvClipValue,
    'hsvClipOwn': hsvClipOwn,
    'hsvClipCross': hsvClipCross,
    'hsvSignatureNaming': hsvSignatureNaming,
    'hsvSignatureMinSigmas': hsvSignatureMinSigmas,
    'v6Spatial': v6Spatial,
    'v6BrightValueMin': v6BrightValueMin,
    'v6CoreValueMin': v6CoreValueMin,
    'v6HueSatMin': v6HueSatMin,
    'v6CenterSpan': v6CenterSpan,
    'hueBins': hueBins,
    'v6MinSigma': v6MinSigma,
    'v6DScale': v6DScale,
    'v6ReflectionWeight': v6ReflectionWeight,
    'v6CoreFeatures': <Object?>[
      for (final V6Feature f in v6CoreFeatures) f.name,
    ],
    'v6ProfileDecision': v6ProfileDecision,
    'v6MinConfidence': v6MinConfidence,
    'v6ReflectionVeto': v6ReflectionVeto,
  };

  /// Сохранённые конфиги могут содержать уже удалённые ключи (`brightY`,
  /// `whiteSatMax`, `redDeltaDivisor`, `coreSideRatio`, `baselineAlpha`,
  /// `whiteOnThreshold`, `redOnThreshold`, `redFracDivisor`, `noiseSigmas`,
  /// `spatialVectors`) — они игнорируются.
  factory LampConfig.fromJson(Map<String, Object?> json) {
    const LampConfig def = LampConfig();
    double d(String key, double fallback) =>
        (json[key] as num?)?.toDouble() ?? fallback;
    int i(String key, int fallback) => (json[key] as num?)?.toInt() ?? fallback;
    bool b(String key, bool fallback) => json[key] as bool? ?? fallback;
    // Список признаков: имена, а не индексы — порядок enum может измениться,
    // а сохранённый конфиг обязан означать одно и то же. Пустой или непонятный
    // список — полный вектор: выключать решение до нуля признаков нельзя.
    List<V6Feature> features(String key) {
      final Object? raw = json[key];
      if (raw is! List) {
        return def.v6CoreFeatures;
      }
      final List<V6Feature> out = <V6Feature>[];
      for (final Object? name in raw) {
        if (name is! String) {
          continue;
        }
        for (final V6Feature f in V6Feature.values) {
          if (f.name == name) {
            out.add(f);
            break;
          }
        }
      }
      return out.isEmpty ? def.v6CoreFeatures : out;
    }

    return LampConfig(
      hitFraction: d('hitFraction', def.hitFraction),
      templateMinSeparation: d(
        'templateMinSeparation',
        def.templateMinSeparation,
      ),
      offRatio: d('offRatio', def.offRatio),
      onConfirmFrames: i('onConfirmFrames', def.onConfirmFrames),
      offConfirmFrames: i('offConfirmFrames', def.offConfirmFrames),
      offConfirmMs: i('offConfirmMs', def.offConfirmMs),
      calibrationFrames: i('calibrationFrames', def.calibrationFrames),
      calibrationMaxNoise: d('calibrationMaxNoise', def.calibrationMaxNoise),
      calibrationNoiseRatio: d(
        'calibrationNoiseRatio',
        def.calibrationNoiseRatio,
      ),
      baselineMaxAgeMinutes: i(
        'baselineMaxAgeMinutes',
        def.baselineMaxAgeMinutes,
      ),
      subsampleStep: i('subsampleStep', def.subsampleStep),
      analysisIsolateThresholdMs: d(
        'analysisIsolateThresholdMs',
        def.analysisIsolateThresholdMs,
      ),
      yuvFullRange: b('yuvFullRange', def.yuvFullRange),
      scoreHistoryPoints: i('scoreHistoryPoints', def.scoreHistoryPoints),
      csvFlushLines: i('csvFlushLines', def.csvFlushLines),
      whiteMinChannel: d('whiteMinChannel', def.whiteMinChannel),
      redMargin: d('redMargin', def.redMargin),
      redMinValue: d('redMinValue', def.redMinValue),
      liveReference: b('liveReference', def.liveReference),
      referenceWindowFrames: i(
        'referenceWindowFrames',
        def.referenceWindowFrames,
      ),
      referencePercentile: d('referencePercentile', def.referencePercentile),
      referenceNoiseSigmas: d('referenceNoiseSigmas', def.referenceNoiseSigmas),
      referenceMinRise: d('referenceMinRise', def.referenceMinRise),
      referenceMaxLevel: d('referenceMaxLevel', def.referenceMaxLevel),
      ringScale: d('ringScale', def.ringScale),
      lumaPercentile: d('lumaPercentile', def.lumaPercentile),
      clipLuma: d('clipLuma', def.clipLuma),
      hsvReference: b('hsvReference', def.hsvReference),
      hsvCoolValueMin: d('hsvCoolValueMin', def.hsvCoolValueMin),
      hsvCoolSatMax: d('hsvCoolSatMax', def.hsvCoolSatMax),
      hsvWarmValueMin: d('hsvWarmValueMin', def.hsvWarmValueMin),
      hsvWarmSatMin: d('hsvWarmSatMin', def.hsvWarmSatMin),
      hsvWarmHueMax: d('hsvWarmHueMax', def.hsvWarmHueMax),
      hsvMinRise: d('hsvMinRise', def.hsvMinRise),
      hsvMaxLevel: d('hsvMaxLevel', def.hsvMaxLevel),
      hsvGate: d('hsvGate', def.hsvGate),
      hsvClipValue: d('hsvClipValue', def.hsvClipValue),
      hsvClipOwn: d('hsvClipOwn', def.hsvClipOwn),
      hsvClipCross: d('hsvClipCross', def.hsvClipCross),
      hsvSignatureNaming: b('hsvSignatureNaming', def.hsvSignatureNaming),
      hsvSignatureMinSigmas: d(
        'hsvSignatureMinSigmas',
        def.hsvSignatureMinSigmas,
      ),
      v6Spatial: b('v6Spatial', def.v6Spatial),
      v6BrightValueMin: d('v6BrightValueMin', def.v6BrightValueMin),
      v6CoreValueMin: d('v6CoreValueMin', def.v6CoreValueMin),
      v6HueSatMin: d('v6HueSatMin', def.v6HueSatMin),
      v6CenterSpan: d('v6CenterSpan', def.v6CenterSpan),
      hueBins: i('hueBins', def.hueBins),
      v6MinSigma: d('v6MinSigma', def.v6MinSigma),
      v6DScale: d('v6DScale', def.v6DScale),
      v6ReflectionWeight: d('v6ReflectionWeight', def.v6ReflectionWeight),
      v6CoreFeatures: features('v6CoreFeatures'),
      v6ProfileDecision: b('v6ProfileDecision', def.v6ProfileDecision),
      v6MinConfidence: d('v6MinConfidence', def.v6MinConfidence),
      v6ReflectionVeto: d('v6ReflectionVeto', def.v6ReflectionVeto),
    );
  }

  /// Способ счёта, собранный из флагов в одно число.
  ///
  /// Флаги при этом обязан связывать запрет совпадения: [withCountMode]
  /// выставляет их ровно одним, а не «ещё одним вариантом true». Иначе
  /// `hsvReference` и `liveReference` одновременно включили бы в детекторе
  /// старшинство одного из них, а UI показывал бы оба.
  ///
  /// Два цветовых режима различаются ровно одним числом — [v6ProfileDecision],
  /// и это не совпадение: по спецификации v6 отличие `HSV` от
  /// `HSV_CALIBRATION` ровно в том, сверяется ли кадр с профилями калибровки
  /// («Similarity to calibrated … profile, when calibration is enabled»). Одно
  /// число на два режима поэтому честнее второго флага: оно не может оказаться
  /// включённым там, где его не видно.
  LampCountMode get countMode => hsvReference
      ? (v6ProfileDecision
            ? LampCountMode.hsvCalibration
            : LampCountMode.hsv)
      : liveReference
      ? LampCountMode.live
      : LampCountMode.etalon;

  /// Копия конфига, переключённая на способ счёта [mode]. Единственный
  /// разрешённый способ менять эти флаги.
  LampConfig withCountMode(LampCountMode mode) => copyWith(
    liveReference: mode == LampCountMode.live,
    hsvReference:
        mode == LampCountMode.hsv || mode == LampCountMode.hsvCalibration,
    v6ProfileDecision: mode == LampCountMode.hsvCalibration,
  );
}

/// Способы решить, какая лампа вспыхнула. Спецификация v6 §MODES требует ровно
/// двух — [hsv] и [hsvCalibration]; [etalon] и [live] помечены прекращёнными и
/// из меню убраны, но в перечислении остаются: сохранённые старые настройки с
/// ними встречаются, и прогон обязан показать включённый способ, даже когда он
/// выпал из выбора (иначе экран выглядит как будто выбран верхний пункт, а
/// переключить его вслепую нельзя).
///
/// Рабочим с 25.11.2026 считается только цветовой счёт, и он обязан идти с
/// калибровкой: по замерам на ручной разметке координат это 60 ошибок против
/// 100 без выученного имени (журнал 46). Оба цветовых режима калибровки требуют
/// одинаково — различаются они лишь тем, что в [hsvCalibration] кадр сверяется
/// с профилями распределений.
enum LampCountMode {
  /// v6 §MODES, режим 1: HSV-отсчёт с вето по перевесу своего подъёма над
  /// чужим ([LampConfig.hsvGate]) и именем вспышки, выученным у калибровки.
  /// Профили распределений на решение НЕ влияют — именно это делает режим
  /// деревом, совпадающим с измеренной v5, и по нему сверяют, чего стоят
  /// профили ([hsvCalibration]).
  hsv,

  /// v6 §MODES, режим 2: тот же HSV-отсчёт плюс сравнение кадра с профилями
  /// OFF/ON/spill обеих ламп (v6 §8): уверенность, подозрение на отражение и
  /// недоказанный кадр. Право у профилей одно — ОТКАЗАТЬ; имя вспышки
  /// по-прежнему даёт измеренный путь, а не профиль.
  hsvCalibration,

  /// ПРЕКРАЩЁН (v6 §MODES: «no additional detection modes»). Доля измеренного
  /// отклика, набранного на калибровке (фон → белая → красная).
  etalon,

  /// ПРЕКРАЩЁН (v6 §MODES: «no additional detection modes»). Подъём яркости
  /// своей рамки над «полом» последних кадров; чужую лампу, перелившую рамку,
  /// не различает вовсе.
  live,
}
