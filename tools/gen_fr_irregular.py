#!/usr/bin/env python3
"""生成法语不规则词形表 fr_irregular.json (词形 -> 原形): 常用不规则动词变位 + 冠词/代词/限定词变形

用法: python3 gen_fr_irregular.py <输出 json>
"""
import json
import sys

forms = {}


def add(lemma, *words):
    for w in words:
        for x in w.split():
            forms.setdefault(x, lemma)


# 限定词 / 代词
add("le", "la les l")
add("un", "une des")
add("de", "du d")
add("à", "au aux")
add("ce", "cette cet ces c ceci cela ça")
add("son", "sa ses")
add("mon", "ma mes")
add("ton", "ta tes")
add("notre", "nos")
add("votre", "vos")
add("leur", "leurs")
add("quel", "quelle quels quelles")
add("lequel", "laquelle lesquels lesquelles duquel auquel desquels auxquels")
add("il", "ils")
add("elle", "elles")
add("lui", "eux")
add("celui", "celle ceux celles celui-ci celle-ci celui-là celle-là")
add("tout", "toute tous toutes")
add("aucun", "aucune")
add("certain", "certaine certains certaines")
add("quelque", "quelques")
add("autre", "autres")
add("même", "mêmes")
add("je", "j")
add("me", "m")
add("te", "t")
add("se", "s")
add("que", "qu")
add("ne", "n")

# 不规则动词: (原形, 现在时, 未完成过去时词干, 将来时词干, 简单过去时, 虚拟式, 过去分词)
VERBS = [
    ("avoir", "ai as a avons avez ont", "av", "aur", "eus eut eûmes eûtes eurent eusse eût", "aie aies ait ayons ayez aient", "eu eue eus eues ayant"),
    ("être", "suis es est sommes êtes sont", "ét", "ser", "fus fut fûmes fûtes furent fusse fût", "sois soit soyons soyez soient", "été étant"),
    ("faire", "fais fait faisons faites font", "fais", "fer", "fis fit fîmes fîtes firent fît", "fasse fasses fassions fassiez fassent", "faite faits faites faisant"),
    ("aller", "vais vas va allons allez vont", "all", "ir", "allai alla allâmes allèrent allât", "aille ailles aillent", "allé allée allés allées allant"),
    ("pouvoir", "peux peut pouvons pouvez peuvent puis", "pouv", "pourr", "pus put purent pût", "puisse puisses puissions puissiez puissent", "pu pouvant"),
    ("vouloir", "veux veut voulons voulez veulent", "voul", "voudr", "voulus voulut voulurent voulût", "veuille veuilles veuillent", "voulu voulue voulant"),
    ("devoir", "dois doit devons devez doivent", "dev", "devr", "dus dut durent dût", "doive doives doivent", "dû due dus dues devant"),
    ("savoir", "sais sait savons savez savent", "sav", "saur", "sus sut surent sût", "sache saches sachions sachiez sachent", "su sue sachant"),
    ("venir", "viens vient venons venez viennent", "ven", "viendr", "vins vint vînmes vinrent vînt", "vienne viennes viennent", "venu venue venus venues venant"),
    ("tenir", "tiens tient tenons tenez tiennent", "ten", "tiendr", "tins tint tinrent tînt", "tienne tiennes tiennent", "tenu tenue tenus tenues tenant"),
    ("voir", "vois voit voyons voyez voient", "voy", "verr", "vis vit vîmes virent vît", "voie voies voient", "vu vue vus vues voyant"),
    ("dire", "dis dit disons dites disent", "dis", "dir", "dîmes dirent dît", "dise dises disent", "dite dits dites disant"),
    ("prendre", "prends prend prenons prenez prennent", "pren", "prendr", "pris prit prîmes prirent prît", "prenne prennes prennent", "prise prises prenant"),
    ("mettre", "mets met mettons mettez mettent", "mett", "mettr", "mis mit mîmes mirent mît", "mette mettes mettent", "mise mises mettant"),
    ("croire", "crois croit croyons croyez croient", "croy", "croir", "crus crut crurent crût", "croie croies croient", "cru crue crus crues croyant"),
    ("connaître", "connais connaît connaissons connaissez connaissent", "connaiss", "connaîtr", "connus connut connurent", "connaisse connaisses", "connu connue connus connues connaissant"),
    ("vivre", "vis vit vivons vivez vivent", "viv", "vivr", "vécus vécut vécurent", "vive vives", "vécu vécue vécus vivant"),
    ("écrire", "écris écrit écrivons écrivez écrivent", "écriv", "écrir", "écrivis écrivit écrivirent", "écrive écrives", "écrite écrits écrites écrivant"),
    ("lire", "lis lit lisons lisez lisent", "lis", "lir", "lus lut lurent", "lise lises", "lu lue lus lues lisant"),
    ("mourir", "meurs meurt mourons mourez meurent", "mour", "mourr", "mourus mourut moururent", "meure meures meurent", "mort morte morts mortes mourant"),
    ("naître", "nais naît naissons naissent", "naiss", "naîtr", "naquis naquit naquirent", "naisse", "né née nés nées naissant"),
    ("ouvrir", "ouvre ouvres ouvrons ouvrez ouvrent", "ouvr", "ouvrir", "ouvris ouvrit ouvrirent", "ouvre", "ouvert ouverte ouverts ouvertes ouvrant"),
    ("offrir", "offre offres offrons offrez offrent", "offr", "offrir", "offris offrit offrirent", "offre", "offert offerte offerts offertes offrant"),
    ("partir", "pars part partons partez partent", "part", "partir", "partis partit partirent", "parte partes partent", "parti partie partis parties partant"),
    ("sortir", "sors sort sortons sortez sortent", "sort", "sortir", "sortis sortit sortirent", "sorte sortes sortent", "sorti sortie sortis sorties sortant"),
    ("sentir", "sens sent sentons sentez sentent", "sent", "sentir", "sentis sentit sentirent", "sente sentes sentent", "senti sentie sentis senties sentant"),
    ("servir", "sers sert servons servez servent", "serv", "servir", "servis servit servirent", "serve serves servent", "servi servie servis servies servant"),
    ("dormir", "dors dort dormons dormez dorment", "dorm", "dormir", "dormis dormit dormirent", "dorme dormes dorment", "dormi dormant"),
    ("suivre", "suit suivons suivez suivent", "suiv", "suivr", "suivis suivit suivirent", "suive suives suivent", "suivi suivie suivis suivies suivant"),
    ("recevoir", "reçois reçoit recevons recevez reçoivent", "recev", "recevr", "reçus reçut reçurent", "reçoive reçoives reçoivent", "reçu reçue reçus reçues recevant"),
    ("boire", "bois boit buvons buvez boivent", "buv", "boir", "bus but burent", "boive boives boivent", "bu bue bus bues buvant"),
    ("courir", "cours court courons courez courent", "cour", "courr", "courus courut coururent", "coure coures courent", "couru courue courant"),
    ("rire", "ris rit rions riez rient", "ri", "rir", "rîmes rirent", "rie ries rient", "riant"),
    ("plaire", "plais plaît plaisons plaisez plaisent", "plais", "plair", "plus plut plurent", "plaise plaises plaisent", "plu plaisant"),
    ("paraître", "parais paraît paraissons paraissez paraissent", "paraiss", "paraîtr", "parus parut parurent", "paraisse paraissent", "paru parue parus parues paraissant"),
    ("falloir", "faut", "fall", "faudr", "fallut", "faille", "fallu"),
    ("valoir", "vaux vaut valons valez valent", "val", "vaudr", "valus valut valurent", "vaille vaillent", "valu valant"),
    ("craindre", "crains craint craignons craignez craignent", "craign", "craindr", "craignis craignit craignirent", "craigne craignent", "crainte craints craintes craignant"),
    ("peindre", "peins peint peignons peignez peignent", "peign", "peindr", "peignis peignit peignirent", "peigne peignent", "peinte peints peintes peignant"),
    ("joindre", "joins joint joignons joignez joignent", "joign", "joindr", "joignis joignit joignirent", "joigne joignent", "jointe joints jointes joignant"),
    ("conduire", "conduis conduit conduisons conduisez conduisent", "conduis", "conduir", "conduisis conduisit conduisirent", "conduise conduisent", "conduite conduits conduites conduisant"),
    ("asseoir", "assieds assied asseyons asseyez asseyent", "assey", "assiér", "assis assit assirent", "asseye asseyent", "assis assise assises asseyant"),
    ("battre", "bats bat battons battez battent", "batt", "battr", "battis battit battirent", "batte battent", "battu battue battus battues battant"),
    ("vaincre", "vaincs vainc vainquons vainquez vainquent", "vainqu", "vaincr", "vainquis vainquit", "vainque vainquent", "vaincu vaincue vaincus vainquant"),
    ("taire", "tais tait taisons taisez taisent", "tais", "tair", "tus tut turent", "taise taisent", "tu tue tus tues taisant"),
    ("cueillir", "cueille cueilles cueillons cueillez cueillent", "cueill", "cueiller", "cueillis cueillit", "cueille", "cueilli cueillie cueillis cueillant"),
]

for lemma, present, imp, fut, ps, subj, part in VERBS:
    add(lemma, present, ps, subj, part)
    add(lemma, " ".join(imp + e for e in ["ais", "ait", "ions", "iez", "aient"]))
    add(lemma, " ".join(fut + e for e in ["ai", "as", "a", "ons", "ez", "ont", "ais", "ait", "ions", "iez", "aient"]))

# 复合动词沿用同样变化
for prefix, base in [("re", "venir"), ("de", "venir"), ("pré", "venir"), ("sou", "venir"), ("con", "venir"), ("de", "voir"),
                     ("re", "voir"), ("pré", "voir"), ("ap", "prendre"), ("com", "prendre"), ("sur", "prendre"), ("re", "prendre"),
                     ("per", "mettre"), ("pro", "mettre"), ("ad", "mettre"), ("sou", "mettre"), ("re", "mettre"), ("con", "tenir"),
                     ("ob", "tenir"), ("re", "tenir"), ("re", "connaître"), ("dis", "paraître"), ("ap", "paraître"), ("re", "faire"),
                     ("dé", "faire"), ("con", "duire"), ("pro", "duire"), ("intro", "duire"), ("tra", "duire"), ("ré", "duire")]:
    lemma = prefix + base
    for form, l in list(forms.items()):
        if l == base and len(form) > 2:
            forms.setdefault(prefix + form, lemma)

json.dump(dict(sorted(forms.items())), open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=0)
print(len(forms), "forms")
