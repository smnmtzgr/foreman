import React from 'react';
import PropTypes from 'prop-types';

import { VerticalNav } from 'patternfly-react';
import { translate as __ } from '../../common/I18n';
import { noop } from '../../common/helpers';

import { getActive, getCurrentPath, handleMenuClick } from './LayoutHelper';
import LayoutContainer from './components/LayoutContainer';
import TaxonomySwitcher from './components/TaxonomySwitcher';
import UserDropdowns from './components/UserDropdowns';
import './layout.scss';

class Layout extends React.Component {
  componentDidMount() {
    const {
      items,
      data,
      fetchMenuItems,
      changeLocation,
      currentLocation,
      changeOrganization,
      currentOrganization,
      changeActiveMenu,
      activeMenu,
      isCollapsed,
      onCollapse,
    } = this.props;
    if (items.length === 0) fetchMenuItems(data);
    if (isCollapsed) onCollapse();

    const activeURLMenu = getActive(data.menu, getCurrentPath());
    if (activeMenu !== activeURLMenu.title) {
      changeActiveMenu(activeURLMenu);
    }

    if (
      data.taxonomies.locations &&
      !!data.locations.current_location &&
      currentLocation !== data.locations.current_location
    ) {
      const initialLocTitle = data.locations.current_location;
      const initialLocId = data.locations.available_locations.find(
        loc => loc.title === initialLocTitle
      ).id;
      changeLocation({ title: initialLocTitle, id: initialLocId });
    }

    if (
      data.taxonomies.organizations &&
      !!data.orgs.current_org &&
      currentOrganization !== data.orgs.current_org
    ) {
      const initialOrgTitle = data.orgs.current_org;
      const initialOrgId = data.orgs.available_organizations.find(
        org => org.title === initialOrgTitle
      ).id;
      changeOrganization({ title: initialOrgTitle, id: initialOrgId });
    }
  }

  render() {
    const {
      items,
      data,
      isLoading,
      isCollapsed,
      onExpand,
      onCollapse,
      changeActiveMenu,
      changeOrganization,
      changeLocation,
      currentOrganization,
      currentLocation,
      activeMenu,
      children,
      history,
    } = this.props;

    return (
      <React.Fragment>
        <VerticalNav
          hoverDelay={100}
          items={items}
          onItemClick={primary =>
            handleMenuClick(primary, activeMenu, changeActiveMenu)
          }
          onNavigate={({ href, preventHref }) =>
            history.push(href, { useTurbolinks: preventHref })
          }
          activePath={`/${__(activeMenu || 'active')}/`}
          onCollapse={onCollapse}
          onExpand={onExpand}
          {...this.props}
        >
          <VerticalNav.Masthead>
            <VerticalNav.Brand
              title={data.brand}
              iconImg={data.logo}
              href={data.root}
            />
            <TaxonomySwitcher
              taxonomiesBool={data.taxonomies}
              currentLocation={currentLocation}
              locations={
                data.taxonomies.locations
                  ? data.locations.available_locations
                  : []
              }
              onLocationClick={changeLocation}
              currentOrganization={currentOrganization}
              organizations={
                data.taxonomies.organizations
                  ? data.orgs.available_organizations
                  : []
              }
              onOrgClick={changeOrganization}
              isLoading={isLoading}
            />
            <UserDropdowns
              notificationUrl={data.notification_url}
              user={data.user}
              changeActiveMenu={changeActiveMenu}
            />
          </VerticalNav.Masthead>
        </VerticalNav>
        <LayoutContainer isCollapsed={isCollapsed}>{children}</LayoutContainer>
      </React.Fragment>
    );
  }
}

Layout.propTypes = {
  children: PropTypes.node,
  history: PropTypes.shape({
    push: PropTypes.func,
  }).isRequired,
  currentOrganization: PropTypes.string,
  currentLocation: PropTypes.string,
  isLoading: PropTypes.bool,
  isCollapsed: PropTypes.bool,
  activeMenu: PropTypes.string,
  fetchMenuItems: PropTypes.func,
  changeActiveMenu: PropTypes.func,
  changeOrganization: PropTypes.func,
  changeLocation: PropTypes.func,
  onExpand: PropTypes.func,
  onCollapse: PropTypes.func,
  items: PropTypes.arrayOf(
    PropTypes.shape({
      title: PropTypes.string.isRequired,
      className: PropTypes.string,
      iconClass: PropTypes.string.isRequired,
      initialActive: PropTypes.bool,
      subItems: PropTypes.arrayOf(
        PropTypes.shape({
          title: PropTypes.string,
          isDivider: PropTypes.bool,
          className: PropTypes.string,
          href: PropTypes.string,
        })
      ),
    })
  ),
  data: PropTypes.shape({
    brand: PropTypes.string,
    menu: PropTypes.arrayOf(
      PropTypes.shape({
        type: PropTypes.string.isRequired,
        name: PropTypes.string.isRequired,
        icon: PropTypes.string.isRequired,
        children: PropTypes.any,
      })
    ),
    locations: PropTypes.shape({
      current_location: PropTypes.string,
      available_locations: PropTypes.arrayOf(
        PropTypes.shape({
          href: PropTypes.string.isRequired,
          id: PropTypes.number.isRequired,
          title: PropTypes.string,
        })
      ),
    }),
    orgs: PropTypes.shape({
      current_org: PropTypes.string,
      available_organizations: PropTypes.arrayOf(
        PropTypes.shape({
          href: PropTypes.string.isRequired,
          id: PropTypes.number.isRequired,
          title: PropTypes.string,
        })
      ),
    }),
    root: PropTypes.string.isRequired,
    logo: PropTypes.string.isRequired,
    notification_url: PropTypes.string.isRequired,
    taxonomies: PropTypes.shape({
      locations: PropTypes.bool.isRequired,
      organizations: PropTypes.bool.isRequired,
    }),
    user: PropTypes.shape({
      current_user: PropTypes.object.isRequired,
      user_dropdown: PropTypes.arrayOf(
        PropTypes.shape({
          children: PropTypes.any,
          icon: PropTypes.string.isRequired,
          name: PropTypes.string.isRequired,
          type: PropTypes.string.isRequired,
        })
      ),
    }),
  }),
};

Layout.defaultProps = {
  children: null,
  items: [],
  data: {},
  currentOrganization: 'Any Organization',
  currentLocation: 'Any Location',
  isLoading: false,
  isCollapsed: false,
  activeMenu: '',
  fetchMenuItems: noop,
  changeActiveMenu: noop,
  changeOrganization: noop,
  changeLocation: noop,
  onExpand: noop,
  onCollapse: noop,
};

export default Layout;
