#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds data/words/adjectives.txt and data/words/animals.txt, the default generator vocabulary
# (PRD §12.1, research 15). Run after script/build_offensive_data.rb (it reads en.json).
#
#   ruby script/build_words_data.rb
#
# adjectives = Glitch friendly-words predicates ∩ petname small/medium adjectives,
#              minus the research watch-list and the words reviewed out below.
# animals    = imsky bird/fish/cat/dog/monkey/snake/apex-predator files ∪ petname small names ∪
#              corpora animals/common, minus the words reviewed out below.
# Both: lowercase a–z only, 3–10 letters, sorted, and no word containing an en term of
# severity >= 3 (any variant) as a substring — the same rule data_test.rb enforces.

require "json"

ROOT = File.expand_path("..", __dir__)
NORM = File.join(ROOT, "docs/research/sources/generation/lists/norm")

def list(name) = File.readlines(File.join(NORM, "#{name}.txt"), chomp: true).map { _1.strip.downcase }
def words(str) = str.split.to_set

BAD = JSON.parse(File.read(File.join(ROOT, "data/offensive/en.json")))
  .select { _1["severity"] >= 3 }.flat_map { [_1["term"]] + _1["variants"] }.uniq

def clean(candidates, reviewed_out, label) # rubocop:disable Metrics/AbcSize
  dropped = Hash.new { |h, k| h[k] = [] }
  kept = candidates.uniq.sort.select do |w|
    reason =
      if !w.match?(/\A[a-z]{3,10}\z/) then :shape
      elsif reviewed_out.include?(w) then :reviewed_out
      elsif (hit = BAD.find { w.include?(_1) }) then :"contains_#{hit}"
      end
    dropped[reason] << w if reason
    reason.nil?
  end
  puts "#{label}: #{kept.size}"
  dropped.each { |why, ws| puts "  #{why} (#{ws.size}): #{ws.join(' ')}" }
  kept
end

# --- adjectives ----------------------------------------------------------------------------------
WATCH_LIST = words("holy hip whip angry bitter broken slimy grave skinny yellow apple chrome") # research 15
ADJ_REVIEWED_OUT = WATCH_LIST | words(<<~W)
  hot cherry mature petite
W
# hot, cherry, mature, petite: sexual or adult-site connotations next to an animal name.

adjectives = clean(list("friendly-predicates") & (list("petname-small-adjectives") + list("petname-medium-adjectives")),
                   ADJ_REVIEWED_OUT, "adjectives")

# --- animals -------------------------------------------------------------------------------------
IMSKY = %w[birds fish cats dogs monkeys snakes apex_predators].flat_map { list("imsky-nouns_#{_1}") }
ANIMALS_REVIEWED_OUT = words(<<~W)
  booby beaver cockatiel cockatoo peacock titmouse bass turkey
  human alien elf ghost ghoul goblin imp troll satyr yeti dragon griffon pegasus phoenix unicorn
  werewolf basilisk monster sunbeam racer glider drum javelin kid lab monitor hermit chow
  maggot louse leech tick flea bedbug hookworm grubworm chigger earwig stinkbug weevil mite aphid
  grub worm slug amoeba sponge insect mammal reptile rodent primate arachnid mollusk
  stud gelding mongrel mutt bitch cougar
  oriental persian siamese burmese balinese javanese himalayan siberian bengal bombay maltese dane
  ginger tom martin molly joey drake robin jay wren kit
  python corgie boiga aotus bocaccio shepherd cobbler angler covey rail darter sole ray cod
W
ANIMALS_REVIEWED_OUT.merge(words(<<~W))
  ayu barbel birman boomslang borzoi burbot cornsnake crappie crawdad dassie eft feist fossa gar
  garfish gelada gobbler hagfish hognose indri jawfish jennet katydid korat krait lancehead langur
  loris mako moray muskox oarfish pika quagga roughy sawfish sawfly sculpin seasnail shad shiner
  skua tahr tarpon tetra wahoo walleye cowbird pipefish killdeer polliwog redbird redfish jaybird
  sunbird kingfish mudfish dogfish monkfish bonefish grackle shrike rook coot tanager razorbill
  harrier lacewing lamprey barnacle krill urchin ringtail vervet tarsier tamarin serval civet
  chamois marten polecat pintail petrel gannet egret
  midge gnat mayfly locust cicada mosquito hornet wasp
  escargot albacore scallop oyster prawn shrimp sardine anchovy herring haddock halibut mackerel
  tilapia pollock mullet carp perch grouper snapper
  longhair marmalade calico tabby bobtail angora chick filly colt moccasin pinscher cattle hog
  amberjack avocet barracuda betta bluegill bream caiman crayfish dory dromedary duckling feline fowl
  foxhound glowworm goshawk grouse guinea gull guppy howler humpback jackdaw kestrel kite kodiak
  komodo ladybird lark lemming liger lioness lionfish loon macaque mallard marmot minnow mole moth
  newt oriole oryx pheasant piglet piranha quetzal raptor rattler rhea salamander sheepdog silkworm
  skink skylark snipe spitz stag starling stingray sturgeon swallow tadpole teal terrapin thrush
  tomcat treefrog vulture warbler weasel westie whippet wildcat woodchuck skunk rat
  ape akita
W
# booby beaver cock* tit* bass turkey: double meanings (research 15, and the brief);
# fantasy creatures, generic class nouns and pests: not animals a person wants as a handle;
# stud gelding mongrel mutt cougar: sexual or derogatory slang; nationality-named cat breeds and
# ginger: read as descriptions of people; tom martin molly joey drake robin jay wren kit: first
# names; python: a trademark; corgie: misspelling; the rest: obscure or not read as an animal.
# Second pass (the ANIMALS_REVIEWED_OUT.merge block), to the ~250 target: obscure names, stinging
# pests, seafood read as food, cat-coat descriptors, chick filly colt moccasin pinscher (slang,
# brands, or half a breed name), weasel skunk rat vulture (used as insults), and the less familiar
# birds, fish and breeds.
# ape and akita: joined after an adjective they spell a severe term across the separator
# (`super_ape` → rape, `deep_akita` → paki), which PRD §10.2 a-2 rejects; the pair check runs in
# script/check_against_corpora.rb.

animals = clean(IMSKY + list("petname-small-names") + list("corpora-animals_common"), ANIMALS_REVIEWED_OUT, "animals")

dir = File.join(ROOT, "data/words")
File.write(File.join(dir, "adjectives.txt"), "#{adjectives.join("\n")}\n")
File.write(File.join(dir, "animals.txt"), "#{animals.join("\n")}\n")
