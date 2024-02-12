# Apply BOGO for identical products
class IdSelector
  def initialize(list)
    @list = list
  end

  def match?(item)
    return @list.include?(item)
  end
end

class PropertySelector
  def initialize(pair)
    @pair = pair
  end

  def match?(hash)
    return hash.has_key?(@pair["key"]) and has.has_value?(@pair["value"])
  end
end

class PercentageDiscount
  def initialize(percent, message)
    @percent = Decimal.new(percent) / 100.0
    @message = message
  end

  def apply(line_item)
    line_discount = line_item.line_price * @percent

    new_line_price = line_item.line_price - line_discount

    line_item.change_line_price(new_line_price, message: @message)

    puts "Discounted line item with variant #{line_item.variant.id} by #{line_discount}."
  end
end

class AmountDiscount
  def initialize(amount, message)
    @amount = Money.new(cents: 100) * amount
    @message = message
  end

  def apply(line_item)
    line_discount = [(@amount * line_item.quantity), Money.zero].max

    new_line_price = line_item.line_price - line_discount

    line_item.change_line_price(new_line_price, message: @message)

    puts "Discounted line item with variant #{line_item.variant.id} by #{line_discount}."
  end
end

# Select every X items
class EveryXPartitioner
  def initialize(paid_item_count)
    @paid_item_count = paid_item_count
  end
  
  def partition(cart, applicable_line_items)
    # Sort the items by price from low to high
    sorted_items = applicable_line_items.sort_by{|line_item| line_item.variant.price}
    # Find the total quantity of items
    total_applicable_quantity = sorted_items.map(&:quantity).reduce(0, :+)
    # Find the quantity of items that must be discounted
    discounted_items_remaining = total_applicable_quantity - total_applicable_quantity % @paid_item_count
    
    # Create an array of items to return
    discounted_items = []

    # Loop over all the items and find those to be discounted
    sorted_items.each do |line_item|
      # Exit the loop if all discounted items have been found
      break if discounted_items_remaining == 0
      # The item will be discounted
      discounted_item = line_item
      if line_item.quantity > discounted_items_remaining
        # If the item has more quantity than what must be discounted, split it
        discounted_item = line_item.split(take: discounted_items_remaining)

        # Insert the newly-created item in the cart, right after the original item
        position = cart.line_items.find_index(line_item)
        cart.line_items.insert(position + 1, discounted_item)
      end
      # Decrement the items left to be discounted
      discounted_items_remaining -= discounted_item.quantity
      # Add the item to be returned
      discounted_items.push(discounted_item)
    end
    #--- 
    # Return the items to be discounted
    discounted_items
  end
end

class BogoCampaign
  def initialize(id_selector, property_selector, discount, partitioner)
    @id_selector = id_selector
    @property_selector = property_selector
    @discount = discount
    @partitioner = partitioner
  end
  
  def build_items_map(eligible_items)
    sorted_items_map = {}
    
    eligible_items.each do |line_item|
      id = line_item.variant.product.id
      item_to_add = line_item
      
      new_item = nil
      
      # add the first line_item
      if sorted_items_map.size == 0
        sorted_items_map[id] = Array.new(1, item_to_add);
      else
        #puts '-----'
        #puts "id: #{id}"
        #puts "old_map: #{sorted_items_map}"
        
        sorted_items_map.each do |key, sorted_items|
          #puts "items: #{sorted_items}"
          # loop through all items to see if we need to expand any
          if key == id
            #puts "will expand #{sorted_items}"
            sorted_items.push(item_to_add)
            # only expand once  
            item_to_add = nil
          
          elsif !sorted_items_map.include?(id) and item_to_add
            #puts "will add [#{id}] to map"
            # only add to map once
            new_item = {
              id => Array.new(1, item_to_add)
            };
            
            item_to_add = nil
          end
        end
        
        # We have to update the map out site the above loop
        if new_item
          #puts new_item
          sorted_items_map = sorted_items_map.merge(new_item)
        end
        
        #puts "new_map: #{sorted_items_map}"
        #puts '-----'
      end
    end
    
    return sorted_items_map
  end

  def run(cart)
    eligible_items = cart.line_items.select do |line_item|
      puts line_item.properties
      @id_selector.match?(line_item.variant.product.id) and @property_selector.match?(line_item.properties)
    end
    
    applicable_items_map =  build_items_map(eligible_items)
    
    applicable_items_map.each do |key, value|
      applicable_items = value
      discount_items = @partitioner.partition(cart, applicable_items)
      
      discount_items.each do |item|
        @discount.apply(item)
      end
    end
  end
end

# ================================ Customizable Settings ================================
# ================================================================
# Spend $X, get Product Y for Z Discount
# ================================================================
SPENDX_GETY_FORZ = [
  {
    product_selector_match_type: :include,
    product_selector_type: :tag,
    product_selectors: ['GWP-FREE'],
    threshold: 200,
    quantity_to_discount: 1,
    discount_type: :percent,
    discount_amount: 100,
    discount_message: 'Free with purchase of $200+',
    coupon_prevent_message: 'Discount codes cannot be combined with free item promotions.',
    whitelisted_discount_code_match_type: :partial,
    whitelisted_discount_code_part: ["PAIGE-"]
  },
]

# ================================ Script Code (do not edit) ================================
# ================================================================
# ProductSelector
# ================================================================
class ProductSelector
  def initialize(match_type, selector_type, selectors)
    @match_type = match_type
    @comparator = match_type == :include ? 'any?' : 'none?'
    @selector_type = selector_type
    @selectors = selectors
  end

  def match?(line_item)
    if self.respond_to?(@selector_type)
      self.send(@selector_type, line_item)
    else
      raise RuntimeError.new('Invalid product selector type')
    end
  end

  def tag(line_item)
    product_tags = line_item.variant.product.tags.map { |tag| tag.downcase.strip }
    @selectors = @selectors.map { |selector| selector.downcase.strip }
    (@selectors & product_tags).send(@comparator)
  end

  def type(line_item)
    @selectors = @selectors.map { |selector| selector.downcase.strip }
    (@match_type == :include) == @selectors.include?(line_item.variant.product.product_type.downcase.strip)
  end

  def vendor(line_item)
    @selectors = @selectors.map { |selector| selector.downcase.strip }
    (@match_type == :include) == @selectors.include?(line_item.variant.product.vendor.downcase.strip)
  end

  def product_id(line_item)
    (@match_type == :include) == @selectors.include?(line_item.variant.product.id)
  end

  def variant_id(line_item)
    (@match_type == :include) == @selectors.include?(line_item.variant.id)
  end

  def subscription(line_item)
    !line_item.selling_plan_id.nil?
  end

  def all(line_item)
    true
  end
end

# ================================================================
# DiscountApplicator
# ================================================================
class DiscountApplicator
  def initialize(discount_type, discount_amount, discount_message)
    @discount_type = discount_type
    @discount_message = discount_message

    @discount_amount = if discount_type == :percent
      1 - (discount_amount * 0.01)
    else
      Money.new(cents: 100) * discount_amount
    end
  end

  def apply(line_item)
    new_line_price = if @discount_type == :percent
      line_item.line_price * @discount_amount
    else
      [line_item.line_price - (@discount_amount * line_item.quantity), Money.zero].max
    end

    line_item.change_line_price(new_line_price, message: @discount_message)
  end
end

# ================================================================
# DiscountLoop
# ================================================================
class DiscountLoop
  def initialize(discount_applicator)
    @discount_applicator = discount_applicator
  end

  def loop_items(cart, line_items, num_to_discount)
    line_items.each do |line_item|
      break if num_to_discount <= 0

      if line_item.quantity > num_to_discount
        split_line_item = line_item.split(take: num_to_discount)
        @discount_applicator.apply(split_line_item)
        position = cart.line_items.find_index(line_item)
        cart.line_items.insert(position + 1, split_line_item)
        break
      else
        @discount_applicator.apply(line_item)
        num_to_discount -= line_item.quantity
      end
    end
  end
end

# ================================================================
# DiscountCodeSelector
#
# Finds whether the supplied discount code matches any of the
# entered codes.
# ================================================================
class DiscountCodeSelector
  def initialize(match_type, discount_codes)
      @comparator = match_type == :exact ? '==' : 'include?'
      @discount_codes = discount_codes.map { |discount_code| discount_code.upcase.strip }
  end
  def match?(discount_code)
      @discount_codes.any?  { |code| discount_code.code.upcase.send(@comparator, code) }
  end
end

# ================================================================
# SpendXGetYForZCampaign
# ================================================================
class SpendXGetYForZCampaign
  def initialize(campaigns)
    @campaigns = campaigns
  end

  def run(cart)
    @campaigns.each do |campaign|
      threshold = Money.new(cents: 100) * campaign[:threshold]

      next if cart.subtotal_price < threshold

      product_selector = ProductSelector.new(
        campaign[:product_selector_match_type],
        campaign[:product_selector_type],
        campaign[:product_selectors],
      )

      eligible_items = cart.line_items.select { |line_item| product_selector.match?(line_item) }
      
      next if eligible_items.nil?

      eligible_items = eligible_items.sort_by { |line_item| line_item.variant.price }
      num_to_discount = campaign[:quantity_to_discount]
      cart_total = cart.subtotal_price
      
      eligible_items.each do |line_item|
        break if num_to_discount <= 0

        if line_item.quantity > num_to_discount
          cart_total -= line_item.variant.price * num_to_discount
          break
        else
          cart_total -= line_item.line_price
          num_to_discount -= line_item.quantity
        end
      end

      next if cart_total < threshold
      
      unless cart.discount_code.nil?
        discount_code_selector_part = DiscountCodeSelector.new(
            campaign[:whitelisted_discount_code_match_type],
            campaign[:whitelisted_discount_code_part]
        )
        
        unless discount_code_selector_part.match?(cart.discount_code)
          if Input.cart.discount_code && eligible_items.length > 0
            Input.cart.discount_code.reject(
              message: campaign[:coupon_prevent_message]
            )
          end
        end
      end
    
      discount_applicator = discount_applicator = DiscountApplicator.new(
        campaign[:discount_type],
        campaign[:discount_amount],
        campaign[:discount_message]
      )

      discount_loop = DiscountLoop.new(discount_applicator)
      discount_loop.loop_items(cart, eligible_items, campaign[:quantity_to_discount])
    end
  end
end

# ====================================
TIER_DEFAULT_DATA = {
  quantity_to_discount: 1,
  discount_type: :percent,
  discount_amount: 100,
  discount_message: 'Free tier reward',
  coupon_prevent_message: 'Discount codes cannot be combined with free item promotions.'
}

class TierRewardCampaign
  def initialize(default_data)
    @tier = default_data
  end

  def run(cart)

    product_selector = ProductSelector.new(
      :include,
      :tag,
      ['TIER_REWARD']
    )

    eligible_items = cart.line_items.select { |line_item| product_selector.match?(line_item) }
    
    return if eligible_items.nil?

    eligible_items = eligible_items.sort_by { |line_item| line_item.variant.price }
    num_to_discount = @tier[:quantity_to_discount]
    
    eligible_items.each do |line_item|
      break if num_to_discount <= 0

      next if line_item.properties['_threshold'].nil?

      threshold = Money.new(cents: 100) * line_item.properties['_threshold']

      cart_total = cart.subtotal_price

      cart_total -= line_item.variant.price * num_to_discount

      if cart_total >= threshold
        discount = PercentageDiscount.new(@tier[:discount_amount], @tier[:discount_message])
        discount.apply(line_item)
      end
    end
    
    if Input.cart.discount_code && eligible_items.length > 0
      Input.cart.discount_code.reject(
        message: @tier[:coupon_prevent_message]
      )
    end
  end
end


# ================================ Customizable Settings ================================
# ================================================================
# Buy Products WXY, get Z Discount
# ================================================================
BUNDLE_DISCOUNTS = [
  {
    bundle_items: [
      {
        product_id: 6791844593766,
        quantity_needed: 1
      },
      {
        product_id: 6791840825446,
        quantity_needed: 1
      },
      {
        product_id: 6791838007398,
        quantity_needed: 1
      }
    ],
    discount_line_item_property: "Training-Kit", 
    discount_type: :percent,
    discount_amount: 30,
    discount_message: "BYLT For Training, get 30% off!",
  },
  {
    bundle_items: [
      {
        product_id: 6850255323238, 
        quantity_needed: 1
      },
      {
        product_id: 6815879266406, 
        quantity_needed: 1
      },
      {
        product_id: 6799876685926, 
        quantity_needed: 1
      }
    ],
    discount_line_item_property: "Workleisure-Kit", 
    discount_type: :percent,
    discount_amount: 30,
    discount_message: "BYLT For Workleisure, get 30% off! ",
  },
  {
    bundle_items: [
      {
        product_id: 6799870099558,
        quantity_needed: 1
      },
      {
        product_id: 6871552229478,
        quantity_needed: 1
      },
      {
        product_id: 6799882354790,
        quantity_needed: 1
      }
    ],
    discount_line_item_property: "Golf-Kit", 
    discount_type: :percent,
    discount_amount: 30,
    discount_message: "BYLT For Golf, get 30% off!",
  },
  {
    bundle_items: [
      {
        product_id: 6850242216038,
        quantity_needed: 1
      },
      {
        product_id: 6815841288294,
        quantity_needed: 1
      },
      {
        product_id: 6815848202342,
        quantity_needed: 1
      }
    ],
    discount_line_item_property: "Office-Kit", 
    discount_type: :percent,
    discount_amount: 30,
    discount_message: "BYLT For The Office, get 30% off!",
  },
  {
    bundle_items: [
      {
        product_id: 6815865307238,
        quantity_needed: 1
      },
      {
        product_id: 6840754339942,
        quantity_needed: 1
      },
      {
        product_id: 6850272788582,
        quantity_needed: 1
      }
    ],
    discount_line_item_property: "Everyday-Kit", 
    discount_type: :percent,
    discount_amount: 30,
    discount_message: "BYLT For Everyday, get 30% off!",  
  }     
]

# ================================ Script Code (do not edit) ================================
# ================================================================
# BundleSelector
#
# Finds any items that are part of the entered bundle and saves
# them.
# ================================================================
class BundleSelector
  def initialize(bundle_items, discount_line_item_property)
    @bundle_items = bundle_items.reduce({}) do |acc, bundle_item|
      acc[bundle_item[:product_id]] = {
        cart_items: [],
        quantity_needed: bundle_item[:quantity_needed],
        total_quantity: 0,
      }

      acc
    end
    @discount_line_item_property = discount_line_item_property
  end

  def build(cart)
    cart.line_items.each do |line_item|
      next if line_item.line_price_changed?
      next unless @bundle_items[line_item.variant.product.id]
      next unless line_item.properties.has_key?(@discount_line_item_property) and line_item.properties[@discount_line_item_property] == 'Yes'

      @bundle_items[line_item.variant.product.id][:cart_items].push(line_item)
      @bundle_items[line_item.variant.product.id][:total_quantity] += line_item.quantity
    end

    @bundle_items
  end
end

# ================================================================
# BundleDiscountCampaign
#
# If the entered bundle is present, the entered discount is
# applied to each item in the bundle.
# ================================================================
class BundleDiscountCampaign
  def initialize(campaigns)
    @campaigns = campaigns
  end

  def run(cart)
    @campaigns.each do |campaign|
      bundle_selector = BundleSelector.new(campaign[:bundle_items],campaign[:discount_line_item_property])
      bundle_items = bundle_selector.build(cart)

      next if bundle_items.any? do |product_id, product_info|
        product_info[:total_quantity] < product_info[:quantity_needed]
      end

      num_bundles = bundle_items.map do |product_id, product_info|
        (product_info[:total_quantity] / product_info[:quantity_needed])
      end

      num_bundles = num_bundles.min.floor

      discount_applicator = DiscountApplicator.new(
        campaign[:discount_type],
        campaign[:discount_amount],
        campaign[:discount_message]
      )

      discount_loop = DiscountLoop.new(discount_applicator)

      bundle_items.each do |product_id, product_info|
        discount_loop.loop_items(
          cart,
          product_info[:cart_items],
          (product_info[:quantity_needed] * num_bundles),
        )
      end
    end
  end
end


CAMPAIGNS = [
  BogoCampaign.new(
    IdSelector.new([
      3482611155046, # Drop-Cut Shirt: LUX
      3482654834790, # Drop-Cut Long Sleeve: LUX
      3486863720550, # Henley Drop-Cut: LUX
      3486867751014, # Henley Drop-Cut Long Sleeve: LUX
      4710060851302, # Drop-Cut Shirt: BYLT Signature
      4709959073894, # Drop-Cut Long Sleeve: BYLT Signature
      3949614039142, # Drop-Cut: LUX Polo
      4894272323686, # Henley Drop-Cut Long Sleeve: BYLT Signature
      4722979438694, # Henley Drop-Cut: BYLT Signature
      4857921011814, # Men's Elite+ Joggers
      4906969006182, # Women's Elite+ Joggers
      4858073481318, # Men's Elite+ Drop-Cut Pullover
      4172918620262, # The BYLT Pant
      4326277447782, # Hybrid Compression Socks
      4892588703846, # Flex Trunks
      4892588605542, # Flex Boxer Briefs
      4892588671078, # AllDay Trunks
      4892588015718, # AllDay Boxer Briefs
      4809750282342, # Training Shorts
      4918130212966, # LUX Basic Crew Split Hem
      5003487740006, # Kids Drop-Cut: LUX
      5003472175206, # Kid's Drop-Cut Long Sleeve: LUX
      5022566711398, # Hybrid Compression No-Show Socks
      6538875764838, # Ringer Tee
      4175116107878, # Drop-Cut V-Neck: LUX
      6538867540070, # BYLT Shorts
      4918121496678, # Kinetic Shorts
      6538877468774, # Basic Crew Split Hem: BYLT Signature
      6538873569382, # Snow Wash Drop-Cut
      4954139132006, # Elite+ Fairway Drop-Cut Pullover
      4362213359718, # Hi-Lo Reversible Bomber Jacket
      6575864348774, # Everyday Pant 2.0
      6575872737382, # Elite+ Jogger Shorts
      6575873917030, # Chino Pant
      6575876866150, # Vista Short Sleeve Button Down
      6575879749734, # Vista Long Sleeve Button Down
      6578681741414, # Essential Bodysuit
      6578663850086, # Essential Cropped Crew
      6642341838950, # District Jacket
      6646293659750, # Active Joggers
      6646710501478, # Performance+ Polo
      6660105207910, # Long Sleeve: LUX Split Hem
      6665245261926, # Coastal Overshirt
      6702498611302, # Performance+ Speckled Polo
      6693880397926, # Snow Wash Drop-Cut V-Neck
      6674043306086, # Kinetic Pant
      6677458452582, # Ace Joggers
      6559236292710, # Drop-Cut: LUX Dotted Polo
      6713433096294, # Women's Essential Jogger
      6713438568550, # Women's Essential Cropped Hoodie
      6711233478758, # Executive Tie
      6724969234534, # Cloud Dye Drop-Cut: BYLT Blend
      6727270826086, # Performance+ Drop-Cut Shirt 
      6701046333542, # Drop-Cut V-Neck Shirt
      6685991469158, # Basic Crew Split Hem Long Sleeve
      6660105207910, # Long Sleeve: LUX Split Hem
      6751441748070, # Drop-Cut Polo
      6738933186662, # Performance+ Ringer Polo
      6769425612902, # Acid Wash Drop-Cut
      6777143984230, # Hooded Drop-Cut Long Sleeve
      6777148342374, # Executive Stretch Long Sleeve
      6798136148070, # Thermal Drop-Cut Long Sleeve
      6804796375142, # Courtside Reversible Bomber Jacket
      6814706532454, # Elite+ Full-Zip Hoodie
      6818582167654, # Everyday Jogger Pant
      6729854156902, # Tech Denim Everyday Pant 2.0
      6833256398950, # Stretch Chino Pant
      6693880397926, # Snow Wash Drop-Cut V-Neck
      6842075250790, # Executive Stretch Short Sleeve
      4918116057190, # Drop-Cut: LUX Hooded Henley
      6846965481574, # Everyday Shorts
      6849378386022, # LUX Straight Hem Tee
      6849243742310, # LUX Straight Hem Polo
      6851533078630, # Kinetic Pant 2.0
      6854560350310, # 19th Hole Polo
      6851615391846, # Drop-Cut: LUX Polka Dot
      6857988178022, # Set Tank
      6858015866982, # Riviera Button Down
      6858030514278, # Paloma Shirt
      6858029170790, # Paloma Shorts
      6857326002278, # Rib High-Neck Longline Bra
      6854802341990, # Rib High-Waist Biker Shorts
      6857203449958, # Rib High-Waist Leggings
      6857198010470, # Rib Mockneck Long Sleeve
      6857196011622, # Rib Mockneck Short Sleeve
      6857188966502, # Rib Tank Top
      6855604502630, # Serene Shacket
      6857321775206, # Women's Flow Joggers
      6855640809574, # Women's Flow Jacket
      6857322692710, # Women's Flow Shorts
      6858733256806, # Metta Crossback Sports Bra
      6854796247142, # Metta High-Waist Leggings
      6853299568742, # Squareneck Bodysuit
      6855646609510, # Endurance Bra
      6857323708518, # Endurance High-Waist Biker Shorts
      6857324658790, # Endurance High-Waist Leggings
      6857240084582, # Women's Fairway Quarter Zip
      6857209446502, # Women's Elite+ Pintuck Jogger
      6855616594022, # Drift Long Sleeve
      6855638122598, # Drift Short Sleeve
      6857238216806, # Women's Everyday Pant
      6865356947558, # Drop-Cut: LUX Ringer Tank
      6866447204454, # Active+ Shorts
      6866446844006, # Linerless Active+ Shorts
      6866443567206, # Performance+ Long Sleeve Polo
      6868973224038, # Kid's Executive Short Sleeve
      6868968308838, # Kid's Thermal Drop-Cut Long Sleeve
      6866555502694, # Kid's Drop-Cut: LUX Polo
      6874228097126, # Signature Polo Long Sleeve
      6873424068710, # Performance+ Circuit
      6873554419814, # Kid's BYLT Pant
      6873555402854, # Kid's Everyday Pant
      6874400718950, # Thermal Henley Drop-Cut Long Sleeve
      6875212054630, # Thermal Hooded Drop-Cut Long Sleeve
      6873603145830, # Bonded No-Show Socks
      6873543442534, # Rib Long Sleeve Split Hem Dress
      6875731230822, # Rib Collar Long Sleeve Bodysuit
      6877594517606, # Kinetic Joggers
      6877944021094, # AllDay Boxers
      6877562568806, # Lightweight LUX Undershirt
      6885228052582, # Contour Scoopneck Long Sleeve Bodysuit
      6885231525990, # Contour Short Sleeve Top
      6942467260518, # Pulse Long Sleeve Drop-Cut
      6942467457126, # Pulse Pullover Drop-Cut Hoodie
      6942467653734, # Pulse Short Sleeve Drop-Cut
      6942461263974, # Pulse Short Sleeve Polo
      6942467981414, # Pulse Short Sleeve Split Hem
      6942468243558, # Pulse Tank
      6727278035046, # Performance+ Drop-Cut Tank
      6727268335718, # Performance+ Drop-Cut Long Sleeve Shirt
    ]),
    PropertySelector.new({
      "key" => "Shirt Bundle",
      "value" => "Yes"
    }),
    PercentageDiscount.new(10, "Bundle and Save"),
    EveryXPartitioner.new(3) # select every 3 items
  ),
  BogoCampaign.new(
    IdSelector.new([
     6757518704742, #5-Item Tank Bundle for $75
    ]),
    PropertySelector.new({
      "key" => "5 Tanks Bundle",
      "value" => "Yes"
    }),
    AmountDiscount.new(2.54, "Bundle 5 Tanks and Save"),
    EveryXPartitioner.new(5) # select every 3 items
  ),
  BogoCampaign.new( 
    IdSelector.new([
        6814744805478, #5-Item Drop-Cut: LUX Bundle for $140
        6822201426022, #5-Item V-Neck LUX Bundle For $140
        6822209585254, #5-Item Ringer Tee Bundle For $140
        6822207160422, #5-Item LUX Split Hem Bundle For $140
        6843205091430, #5-Item Long Sleeve: BYLT Signature Bundle For $140
    ]),
    PropertySelector.new({
      "key" => "5 items Bundle - Save $7.00",
      "value" => "Yes"
    }),
    AmountDiscount.new(7.00, "Bundle and Save"),
    EveryXPartitioner.new(5) # select every 5 items
  ),
  BogoCampaign.new( 
      IdSelector.new([
          6846091395174, #5-Item Long Sleeve: LUX Split Hem Bundle For $160
          6843193884774, #5-Item Long Sleeve: LUX Bundle For $160
          
      ]),
      PropertySelector.new({
        "key" => "5 items Bundle - Save $8.00",
        "value" => "Yes"
      }),
      AmountDiscount.new(8.00, "Bundle and Save"),
      EveryXPartitioner.new(5) # select every 5 items
  ),
    BogoCampaign.new( 
      IdSelector.new([
          6871675666534, #2-Item Everyday Pant 2.0 Bundle For $204
          6924473172070, #2-Item Everyday Jogger Pant Bundle For $204
          6924473335910, #2-Item Everyday Pant 2.0 - Standard Fit Bundle For $204
      ]),
      PropertySelector.new({
        "key" => "2 items Bundle - Save $18.00",
        "value" => "Yes"
      }),
      AmountDiscount.new(18.00, "Bundle and Save"),
      EveryXPartitioner.new(2) # select every 2 items
  ),
    BogoCampaign.new( 
      IdSelector.new([
          6868590133350, #2-Item Kinetic Shorts Bundle For $140
      ]),
      PropertySelector.new({
        "key" => "2 items Bundle - Save $12.00",
        "value" => "Yes"
      }),
      AmountDiscount.new(12.00, "Bundle and Save"),
      EveryXPartitioner.new(2) # select every 2 items  
  ),
    BogoCampaign.new( 
      IdSelector.new([
          6925722222694, #2-Item Elite+ Fairway Drop-Cut Pullover for $245
      ]),
      PropertySelector.new({
        "key" => "2 items Bundle - Save $22.50",
        "value" => "Yes"
      }),
      AmountDiscount.new(22.50, "Bundle and Save"),
      EveryXPartitioner.new(2) # select every 2 items  
  ),      
    BogoCampaign.new( 
      IdSelector.new([
          6858876944486, #5-Item LUX Tank Bundle for $120
          6814765711462, #5-Item BYLT Signature Bundle for $120
          6822199066726, #5-Item V-Neck BYLT Signature Bundle For $120
      ]),
      PropertySelector.new({
        "key" => "5 items Bundle - Save $6.00",
        "value" => "Yes"
      }),
      AmountDiscount.new(6.00, "Bundle and Save"),
      EveryXPartitioner.new(5) # select every 5 items
  ),
    BogoCampaign.new( 
      IdSelector.new([
          6858877960294, #5-Item BYLT Signature Tank for $100
      ]),
      PropertySelector.new({
        "key" => "5 items Bundle - Save $5.00",
        "value" => "Yes"
      }),
      AmountDiscount.new(5.00, "Bundle and Save"),
      EveryXPartitioner.new(5) # select every 5 items
  ),
  BogoCampaign.new( 
      IdSelector.new([
          6846092050534, #5-Item Snow Wash Drop-Cut Bundle For $128
      ]),
      PropertySelector.new({
        "key" => "5 items Bundle - Save $6.40",
        "value" => "Yes"
      }),
      AmountDiscount.new(6.40, "Bundle and Save"),
      EveryXPartitioner.new(5) # select every 5 items
  ),
  SpendXGetYForZCampaign.new(SPENDX_GETY_FORZ),
  TierRewardCampaign.new(TIER_DEFAULT_DATA),
  BundleDiscountCampaign.new(BUNDLE_DISCOUNTS)
]

# Iterate through each of the discount campaigns.
CAMPAIGNS.each do |campaign|
  # Apply the campaign onto the cart.
  campaign.run(Input.cart)
end

Output.cart = Input.cart
